#import "mica_remote_server.h"
#import <CommonCrypto/CommonRandom.h>
#import <CommonCrypto/CommonDigest.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <arpa/inet.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <poll.h>
#import <netdb.h>
#import <math.h>
#import <sys/stat.h>
#import <Network/Network.h>
#import <Security/Security.h>

static const NSUInteger kRemoteRequestLimit = 32768;
static const NSUInteger kRemoteClientLimit = 8;

@interface MicaRemoteServer ()
@property(nonatomic, copy, readwrite) NSString *pairingCode;
@property(nonatomic, copy, readwrite) NSString *localURL;
@property(nonatomic, copy, readwrite) NSString *pairingPayload;
@property(nonatomic) int fd;
@property(nonatomic) nw_listener_t tlsListener;
@property(nonatomic) nw_path_monitor_t pathMonitor;
@property(nonatomic) dispatch_source_t source;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) NSUInteger clients;
@property(nonatomic) NSUInteger tlsClients;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *clientFDs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *pairAttempts;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *devicesByID;
@property(nonatomic, strong) NSDate *startedAt;
@property(nonatomic, strong) NSNetService *bonjour;
@property(nonatomic, copy) NSString *boundAddress;
@property(nonatomic, copy) NSData *certificateData;
@property(nonatomic) struct in_addr boundMask;
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL active;
- (BOOL)pairingAllowedForPeer:(NSString *)peer generation:(uint64_t)generation code:(NSString *)code
                     deviceID:(NSString *)deviceID deviceName:(NSString *)deviceName token:(NSString **)token;
- (NSData *)bridgeRequestData:(NSData *)request peer:(NSString *)peer expectedHost:(NSString *)expectedHost generation:(uint64_t)generation;
@end

static BOOL MicaPrivateIPv4(uint32_t host) {
    uint8_t a = (uint8_t)(host >> 24), b = (uint8_t)(host >> 16);
    return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

static NSString *MicaRandomPairingCode(void) {
    uint32_t value = 0;
    if (CCRandomGenerateBytes(&value, sizeof(value)) != kCCSuccess) return nil;
    return [NSString stringWithFormat:@"%06u", value % 1000000];
}

static NSString *MicaRandomToken(void) {
    uint8_t random[32];
    if (CCRandomGenerateBytes(random, sizeof(random)) != kCCSuccess) return nil;
    NSMutableString *token = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(random); i++) [token appendFormat:@"%02x", random[i]];
    return token;
}

static NSString *MicaLocalHostName(void) {
    NSTask *task = [NSTask new]; task.launchPath = @"/usr/sbin/scutil"; task.arguments = @[@"--get", @"LocalHostName"];
    NSPipe *pipe = [NSPipe pipe]; task.standardOutput = pipe; task.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try { [task launch]; [task waitUntilExit]; } @catch (__unused NSException *e) { return nil; }
    NSData *data = [[pipe.fileHandleForReading readDataToEndOfFile] copy];
    NSString *name = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRegularExpression *valid = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$" options:0 error:nil];
    if (task.terminationStatus != 0 || !name.length || [valid numberOfMatchesInString:name options:0 range:NSMakeRange(0, name.length)] != 1) return nil;
    return name.lowercaseString;
}

@implementation MicaRemoteServer
+ (instancetype)sharedServer {
    static MicaRemoteServer *server;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ server = [self new]; });
    return server;
}

- (instancetype)init {
    if ((self = [super init])) {
        _fd = -1;
        _queue = dispatch_queue_create("com.mica.remote.state", DISPATCH_QUEUE_SERIAL);
        _clientFDs = [NSMutableDictionary dictionary];
        _pairAttempts = [NSMutableDictionary dictionary];
        _devicesByID = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)findLANAddress:(NSString **)address netmask:(struct in_addr *)mask {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return NO;
    int bestScore = -1;
    for (struct ifaddrs *item = list; item; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET ||
            !item->ifa_netmask || item->ifa_netmask->sa_family != AF_INET ||
            !(item->ifa_flags & IFF_UP) || !(item->ifa_flags & IFF_RUNNING) ||
            (item->ifa_flags & (IFF_LOOPBACK | IFF_POINTOPOINT))) continue;
        struct sockaddr_in *sin = (struct sockaddr_in *)item->ifa_addr;
        uint32_t host = ntohl(sin->sin_addr.s_addr);
        if (!MicaPrivateIPv4(host)) continue;
        if (strcmp(item->ifa_name, "en1") != 0 && strcmp(item->ifa_name, "en0") != 0) continue;
        int score = 2;
        if (score <= bestScore) continue;
        bestScore = score;
        char addressBytes[INET_ADDRSTRLEN] = {0};
        if (!inet_ntop(AF_INET, &sin->sin_addr, addressBytes, sizeof(addressBytes))) continue;
        *address = [NSString stringWithUTF8String:addressBytes];
        *mask = ((struct sockaddr_in *)item->ifa_netmask)->sin_addr;
    }
    freeifaddrs(list);
    return bestScore >= 0 && (*address).length > 0;
}

- (sec_identity_t)tlsIdentityWithCertificateData:(NSData **)certificateData {
    NSString *localHost = [(MicaLocalHostName() ?: @"mica-host") stringByAppendingString:@".local"];
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:nil]) return nil;
    NSString *certificatePath = [directory stringByAppendingPathComponent:@"certificate.pem"];
    NSString *keyPath = [directory stringByAppendingPathComponent:@"private.pem"];
    NSTask *task = [NSTask new]; task.launchPath = @"/usr/bin/openssl";
    task.arguments = @[@"req", @"-x509", @"-newkey", @"rsa:2048", @"-nodes", @"-days", @"3650", @"-subj", @"/CN=Mica Remote", @"-addext", [NSString stringWithFormat:@"subjectAltName=DNS:%@", localHost], @"-addext", @"extendedKeyUsage=serverAuth", @"-keyout", keyPath, @"-out", certificatePath];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice]; task.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try { [task launch]; [task waitUntilExit]; } @catch (__unused NSException *e) { [NSFileManager.defaultManager removeItemAtPath:directory error:nil]; return nil; }
    if (task.terminationStatus != 0) { [NSFileManager.defaultManager removeItemAtPath:directory error:nil]; return nil; }
    sec_identity_t protocolIdentity = nil;
    NSString *password = MicaRandomToken();
    NSString *p12Path = [directory stringByAppendingPathComponent:@"identity.p12"];
    task = [NSTask new]; task.launchPath = @"/usr/bin/openssl";
    task.arguments = @[@"pkcs12", @"-export", @"-inkey", keyPath, @"-in", certificatePath, @"-out", p12Path, @"-passout", [@"pass:" stringByAppendingString:password]];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice]; task.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try { [task launch]; [task waitUntilExit]; } @catch (__unused NSException *e) { [NSFileManager.defaultManager removeItemAtPath:directory error:nil]; return nil; }
    NSData *p12 = task.terminationStatus == 0 ? [NSData dataWithContentsOfFile:p12Path] : nil;
    CFArrayRef imported = NULL;
    OSStatus status = p12 ? SecPKCS12Import((__bridge CFDataRef)p12, (__bridge CFDictionaryRef)@{(__bridge id)kSecImportExportPassphrase:password}, &imported) : errSecDecode;
    if (status == errSecSuccess && imported && CFArrayGetCount(imported)) {
        NSDictionary *item = CFBridgingRelease(CFRetain(CFArrayGetValueAtIndex(imported, 0)));
        SecIdentityRef identity = (__bridge SecIdentityRef)item[(__bridge id)kSecImportItemIdentity];
        SecCertificateRef cert = NULL;
        if (identity && SecIdentityCopyCertificate(identity, &cert) == errSecSuccess) {
            NSData *der = CFBridgingRelease(SecCertificateCopyData(cert));
            protocolIdentity = sec_identity_create(identity);
            CFRelease(cert);
            if (certificateData) *certificateData = der;
        }
        CFRelease(imported);
    }
    [NSFileManager.defaultManager removeItemAtPath:p12Path error:nil];
    [NSFileManager.defaultManager removeItemAtPath:certificatePath error:nil];
    [NSFileManager.defaultManager removeItemAtPath:keyPath error:nil];
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    return protocolIdentity;
}

- (void)startTLSListenerForInterface:(NSString *)interfaceName {
    nw_path_monitor_t monitor = nw_path_monitor_create_with_type(nw_interface_type_wifi);
    dispatch_queue_t queue = dispatch_queue_create("com.mica.remote.network", DISPATCH_QUEUE_SERIAL);
    nw_path_monitor_set_queue(monitor, queue);
    __block nw_interface_t wifiInterface = NULL;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        __block BOOL found = NO;
        nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) {
            if (nw_interface_get_type(interface) == nw_interface_type_wifi) { wifiInterface = interface; found = YES; }
            return true;
        });
        NSString *currentAddress = nil; struct in_addr currentMask = {0};
        BOOL sameAddress = [self findLANAddress:&currentAddress netmask:&currentMask] && [currentAddress isEqualToString:self.boundAddress];
        if ((!found || !sameAddress) && self.tlsListener) dispatch_async(dispatch_get_main_queue(), ^{ [self stop]; });
        dispatch_semaphore_signal(ready);
    });
    nw_path_monitor_start(monitor);
    dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    nw_interface_t wifi = wifiInterface;
    if (!wifi) { nw_path_monitor_cancel(monitor); return; }
    NSData *certificate = nil;
    sec_identity_t protocolIdentity = [self tlsIdentityWithCertificateData:&certificate];
    if (!protocolIdentity || !certificate.length) { nw_path_monitor_cancel(monitor); return; }
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
        sec_protocol_options_t options = nw_tls_copy_sec_protocol_options(tls);
        sec_protocol_options_set_min_tls_protocol_version(options, tls_protocol_version_TLSv12);
        sec_protocol_options_set_local_identity(options, protocolIdentity);
    }, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_require_interface(parameters, wifi);
    nw_listener_t listener = nw_listener_create_with_port("8765", parameters);
    if (!listener) { nw_path_monitor_cancel(monitor); return; }
    self.pathMonitor = monitor; self.tlsListener = listener;
    nw_listener_set_queue(listener, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) { [self handleTLSConnection:connection generation:self.generation]; });
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, __unused nw_error_t error) {
        if (state == nw_listener_state_failed) dispatch_async(dispatch_get_main_queue(), ^{ [self stop]; });
    });
    nw_listener_start(listener);
    NSString *host = [NSString stringWithFormat:@"%@.local", MicaLocalHostName() ?: @"mica-host"];
    self.localURL = [NSString stringWithFormat:@"https://%@:%d/", host, 8765];
    self.certificateData = certificate;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(certificate.bytes, (CC_LONG)certificate.length, digest);
    NSMutableString *pin = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [pin appendFormat:@"%02x", digest[i]];
    self.pairingPayload = [NSString stringWithFormat:@"mica://pair?host=%@&port=8765&pin=%@&code=%@", host, pin, self.pairingCode];
}

- (void)handleTLSConnection:(nw_connection_t)connection generation:(uint64_t)generation {
    __block BOOL reserved = NO;
    dispatch_sync(self.queue, ^{ if (self.active && self.generation == generation && self.tlsClients < kRemoteClientLimit) { self.tlsClients++; reserved = YES; } });
    if (!reserved) { nw_connection_cancel(connection); return; }
    __block BOOL released = NO;
    void (^releaseClient)(void) = ^{
        if (released) return;
        released = YES;
        dispatch_sync(self.queue, ^{ if (self.generation == generation && self.tlsClients) self.tlsClients--; });
    };
    nw_connection_set_queue(connection, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, __unused nw_error_t error) {
        if (state == nw_connection_state_ready) [self receiveTLSRequest:connection generation:generation buffer:[NSMutableData data]];
        else if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) releaseClient();
    });
    nw_connection_start(connection);
    // Bound the TLS handshake and the whole request lifetime. Without this,
    // clients that connect and send nothing can occupy every listener slot.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if ([self requestGenerationIsActive:generation]) nw_connection_cancel(connection);
    });
}

- (void)receiveTLSRequest:(nw_connection_t)connection generation:(uint64_t)generation buffer:(NSMutableData *)buffer {
    nw_connection_receive(connection, 1, 4096, ^(dispatch_data_t content, __unused nw_content_context_t context, bool complete, __unused nw_error_t error) {
        if (content) dispatch_data_apply(content, ^bool(__unused dispatch_data_t region, __unused size_t offset, const void *bytes, size_t length) { [buffer appendBytes:bytes length:length]; return true; });
        NSString *request = [[NSString alloc] initWithData:buffer encoding:NSISOLatin1StringEncoding];
        NSRange end = [request rangeOfString:@"\r\n\r\n"];
        BOOL ready = NO;
        if (end.location != NSNotFound) {
            NSString *header = [request substringToIndex:end.location];
            NSUInteger bodyLength = 0;
            for (NSString *line in [header componentsSeparatedByString:@"\r\n"]) if ([line.lowercaseString hasPrefix:@"content-length:"]) bodyLength = (NSUInteger)[[[line substringFromIndex:15] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] integerValue];
            ready = bodyLength <= kRemoteRequestLimit && buffer.length >= end.location + 4 + bodyLength;
        }
        if (!ready && !complete && buffer.length <= kRemoteRequestLimit) { [self receiveTLSRequest:connection generation:generation buffer:buffer]; return; }
        nw_endpoint_t peerEndpoint = nw_connection_copy_endpoint(connection);
        const struct sockaddr *peerAddress = nw_endpoint_get_address(peerEndpoint);
        struct sockaddr_in peerV4 = {0};
        BOOL localWiFiIPv6 = NO;
        if (peerAddress && peerAddress->sa_family == AF_INET) peerV4 = *(const struct sockaddr_in *)peerAddress;
        else if (peerAddress && peerAddress->sa_family == AF_INET6) {
            const struct sockaddr_in6 *peerV6 = (const struct sockaddr_in6 *)peerAddress;
            if (IN6_IS_ADDR_V4MAPPED(&peerV6->sin6_addr)) {
                peerV4.sin_family = AF_INET;
                memcpy(&peerV4.sin_addr, &peerV6->sin6_addr.s6_addr[12], sizeof(peerV4.sin_addr));
            } else if (IN6_IS_ADDR_LINKLOCAL(&peerV6->sin6_addr)) localWiFiIPv6 = YES;
        } else if (peerEndpoint && nw_endpoint_get_type(peerEndpoint) == nw_endpoint_type_host) {
            const char *host = nw_endpoint_get_hostname(peerEndpoint);
            if (host) {
                peerV4.sin_family = AF_INET;
                if (inet_pton(AF_INET, host, &peerV4.sin_addr) != 1) {
                    struct in6_addr peerV6 = {0};
                    peerV4.sin_family = 0;
                    if (inet_pton(AF_INET6, host, &peerV6) == 1 && IN6_IS_ADDR_LINKLOCAL(&peerV6)) localWiFiIPv6 = YES;
                }
            }
        }
        char peerBytes[INET_ADDRSTRLEN] = {0};
        NSString *peer = peerV4.sin_family == AF_INET && inet_ntop(AF_INET, &peerV4.sin_addr, peerBytes, sizeof(peerBytes)) ? [NSString stringWithUTF8String:peerBytes] : @"";
        if (localWiFiIPv6 && peerEndpoint && nw_endpoint_get_hostname(peerEndpoint)) peer = [NSString stringWithUTF8String:nw_endpoint_get_hostname(peerEndpoint)] ?: @"";
        BOOL localPeer = localWiFiIPv6 || (peerV4.sin_family == AF_INET && [self peer:peerV4 isOnBoundLAN:NO]);
        if (!localPeer || !peer.length || generation != self.generation) { nw_connection_cancel(connection); return; }
        NSString *host = self.localURL.length ? [NSURL URLWithString:self.localURL].host : @"";
        NSString *expectedHost = [NSString stringWithFormat:@"%@:%d", host, 8765];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSData *response = [self bridgeRequestData:buffer peer:peer expectedHost:expectedHost generation:generation];
            dispatch_data_t data = dispatch_data_create(response.bytes, response.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            nw_connection_send(connection, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(__unused nw_error_t sendError) { nw_connection_cancel(connection); });
        });
    });
}

- (BOOL)start {
    NSAssert(NSThread.isMainThread, @"Mica remote lifecycle is main-thread confined");
    if (self.source) return YES;
    NSString *address = nil;
    struct in_addr mask = {0};
    if (getenv("MICA_REMOTE_TEST_MODE")) {
        address = @"127.0.0.1";
        inet_pton(AF_INET, "255.0.0.0", &mask);
    } else {
        struct ifaddrs *addresses = NULL;
        BOOL foundWiFiAddress = NO;
        if (getifaddrs(&addresses) == 0) {
            for (struct ifaddrs *item = addresses; item; item = item->ifa_next) {
                if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET || !item->ifa_netmask || !(item->ifa_flags & IFF_UP) || !(item->ifa_flags & IFF_RUNNING) || !(item->ifa_flags & IFF_BROADCAST) || (item->ifa_flags & (IFF_LOOPBACK | IFF_POINTOPOINT))) continue;
                if (strcmp(item->ifa_name, "en1") != 0 && strcmp(item->ifa_name, "en0") != 0) continue;
                struct sockaddr_in *sin = (struct sockaddr_in *)item->ifa_addr;
                if (!MicaPrivateIPv4(ntohl(sin->sin_addr.s_addr))) continue;
                char bytes[INET_ADDRSTRLEN] = {0};
                if (!inet_ntop(AF_INET, &sin->sin_addr, bytes, sizeof(bytes))) continue;
                address = [NSString stringWithUTF8String:bytes];
                mask = ((struct sockaddr_in *)item->ifa_netmask)->sin_addr;
                foundWiFiAddress = YES;
                break;
            }
            freeifaddrs(addresses);
        }
        if (!foundWiFiAddress) return NO;
    }

    if (!getenv("MICA_REMOTE_TEST_MODE")) {
        struct ifaddrs *interfaces = NULL; NSString *wifiName = nil; NSString *wifiAddress = address;
        if (getifaddrs(&interfaces) == 0) {
            for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
                if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET || !item->ifa_netmask || !(item->ifa_flags & IFF_UP) || !(item->ifa_flags & IFF_RUNNING) || !(item->ifa_flags & IFF_BROADCAST) || (item->ifa_flags & (IFF_LOOPBACK|IFF_POINTOPOINT))) continue;
                if (strcmp(item->ifa_name, "en1") != 0 && strcmp(item->ifa_name, "en0") != 0) continue;
                uint32_t ip = ntohl(((struct sockaddr_in *)item->ifa_addr)->sin_addr.s_addr);
                if (!MicaPrivateIPv4(ip)) continue;
                char addressBytes[INET_ADDRSTRLEN] = {0};
                if (!inet_ntop(AF_INET, &((struct sockaddr_in *)item->ifa_addr)->sin_addr, addressBytes, sizeof(addressBytes))) continue;
                wifiName = [NSString stringWithUTF8String:item->ifa_name];
                wifiAddress = [NSString stringWithUTF8String:addressBytes];
                address = wifiAddress;
                mask = ((struct sockaddr_in *)item->ifa_netmask)->sin_addr;
                break;
            }
            freeifaddrs(interfaces);
        }
        if (!wifiName || !wifiAddress) return NO;
        NSString *code = MicaRandomPairingCode(); if (!code) return NO;
        self.boundAddress = address; self.boundMask = mask;
        dispatch_sync(self.queue, ^{ self.generation++; self.active = YES; self.pairingCode = code; self.startedAt = NSDate.date; self.clients = 0; self.tlsClients = 0; [self.clientFDs removeAllObjects]; [self.pairAttempts removeAllObjects]; });
        [self startTLSListenerForInterface:wifiName];
        if (!self.tlsListener) { dispatch_sync(self.queue, ^{ self.active = NO; self.generation++; }); self.pairingCode = nil; self.boundAddress = nil; return NO; }
        if (!getenv("MICA_REMOTE_TEST_MODE")) {
            self.bonjour = [[NSNetService alloc] initWithDomain:@"local." type:@"_mica-remote._tcp." name:[NSString stringWithFormat:@"Mica-%@", NSProcessInfo.processInfo.hostName] port:8765]; [self.bonjour publish];
        }
        return YES;
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) { close(fd); return NO; }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in local = {0};
    local.sin_family = AF_INET;
    local.sin_port = htons(8765);
    if (inet_pton(AF_INET, address.UTF8String, &local.sin_addr) != 1 ||
        bind(fd, (struct sockaddr *)&local, sizeof(local)) != 0 || listen(fd, 8) != 0) {
        close(fd); return NO;
    }
    if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK) != 0) { close(fd); return NO; }
    NSString *code = MicaRandomPairingCode();
    if (!code) { close(fd); return NO; }

    self.fd = fd;
    self.boundAddress = address;
    self.boundMask = mask;
    self.localURL = [NSString stringWithFormat:@"http://%@:%d/", address, 8765];
    dispatch_sync(self.queue, ^{
        self.generation++;
        self.active = YES;
        self.pairingCode = code;
        self.startedAt = NSDate.date;
        self.clients = 0;
        [self.clientFDs removeAllObjects];
        [self.pairAttempts removeAllObjects];
    });
    self.source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_main_queue());
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.source, ^{ [weakSelf acceptClients]; });
    dispatch_resume(self.source);
    if (!getenv("MICA_REMOTE_TEST_MODE")) {
        self.bonjour = [[NSNetService alloc] initWithDomain:@"local." type:@"_mica-remote._tcp."
            name:[NSString stringWithFormat:@"Mica-%@", NSProcessInfo.processInfo.hostName] port:8765];
        [self.bonjour publish];
    }
    return YES;
}

- (BOOL)isRunning { return self.source != nil || self.tlsListener != nil; }

- (BOOL)peer:(struct sockaddr_in)peer isOnBoundLAN:(BOOL)unused {
    (void)unused;
    if (peer.sin_family != AF_INET) return NO;
    uint32_t host = ntohl(peer.sin_addr.s_addr);
    uint32_t localNetworkOrder = 0, mask = ntohl(self.boundMask.s_addr);
    if (inet_pton(AF_INET, self.boundAddress.UTF8String, &localNetworkOrder) != 1) return NO;
    uint32_t local = ntohl(localNetworkOrder);
    if (getenv("MICA_REMOTE_TEST_MODE")) return (host >> 24) == 127;
    return MicaPrivateIPv4(host) && ((host & mask) == (local & mask));
}

- (void)acceptClients {
    NSAssert(NSThread.isMainThread, @"Accept callback must serialize with terminal forks");
    if (!self.source || self.fd < 0) return;
    for (;;) {
        struct sockaddr_in peer = {0}; socklen_t peerLength = sizeof(peer);
        int client = accept(self.fd, (struct sockaddr *)&peer, &peerLength);
        if (client < 0) { if (errno == EINTR) continue; break; }
        if (![self peer:peer isOnBoundLAN:NO] || fcntl(client, F_SETFD, FD_CLOEXEC) != 0) { close(client); continue; }
        __block int reserved = 0; __block uint64_t generation = 0;
        dispatch_sync(self.queue, ^{
            if (self.active && self.clients < kRemoteClientLimit) {
                self.clients++; generation = self.generation; self.clientFDs[@(client)] = @(generation); reserved = 1;
            }
        });
        if (!reserved) { close(client); continue; }
        struct timeval timeout = {2, 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        int noSigPipe = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        char hostBytes[INET_ADDRSTRLEN] = {0}; inet_ntop(AF_INET, &peer.sin_addr, hostBytes, sizeof(hostBytes));
        NSString *host = [NSString stringWithUTF8String:hostBytes] ?: @"unknown";
        NSString *expectedHost = [NSString stringWithFormat:@"%@:%d", self.boundAddress, 8765];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self handleClient:client peer:host expectedHost:expectedHost generation:generation];
        });
    }
}

- (BOOL)requestGenerationIsActive:(uint64_t)generation {
    __block BOOL active = NO;
    dispatch_sync(self.queue, ^{ active = self.active && self.generation == generation; });
    return active;
}

- (NSData *)remotePageData {
    NSString *override = NSProcessInfo.processInfo.environment[@"MICA_REMOTE_PAGE_PATH"];
    NSString *path = override.length ? override : [NSBundle.mainBundle pathForResource:@"mica_remote" ofType:@"html"];
    if (!path.length) path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"resources/mica_remote.html"];
    return [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil] ?: [NSData data];
}

- (void)performMainActionForGeneration:(uint64_t)generation action:(dispatch_block_t)action {
    dispatch_sync(dispatch_get_main_queue(), ^{
        if ([self requestGenerationIsActive:generation]) action();
    });
}

- (NSData *)bridgeRequestData:(NSData *)request peer:(NSString *)peer expectedHost:(NSString *)expectedHost generation:(uint64_t)generation {
    int descriptors[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) != 0) return NSData.data;
    int bridgeFD = descriptors[0], handlerFD = descriptors[1];
    fcntl(bridgeFD, F_SETFD, FD_CLOEXEC);
    fcntl(handlerFD, F_SETFD, FD_CLOEXEC);

    // The handler must drain the request while the bridge writes it, then the
    // bridge must drain the response while the handler writes it. In
    // particular, remote-page responses exceed the default socket buffer.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self handleClient:handlerFD peer:peer expectedHost:expectedHost generation:generation];
    });
    const uint8_t *input = request.bytes;
    size_t remaining = request.length;
    while (remaining) {
        ssize_t n = write(bridgeFD, input, remaining);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        input += n;
        remaining -= (size_t)n;
    }
    shutdown(bridgeFD, SHUT_WR);
    NSMutableData *response = [NSMutableData data];
    uint8_t output[4096];
    for (;;) {
        ssize_t n = read(bridgeFD, output, sizeof(output));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        [response appendBytes:output length:(NSUInteger)n];
    }
    close(bridgeFD);
    return response;
}

- (void)respond:(int)fd status:(NSInteger)status type:(NSString *)type body:(NSData *)body {
    NSString *reason = status == 200 ? @"OK" : status == 204 ? @"No Content" : status == 400 ? @"Bad Request" :
        status == 401 ? @"Unauthorized" : status == 404 ? @"Not Found" : status == 413 ? @"Payload Too Large" :
        status == 403 ? @"Forbidden" : status == 429 ? @"Too Many Requests" : @"Internal Server Error";
    NSString *headers = [NSString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n"
         "X-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n"
         "Permissions-Policy: microphone=(self), on-device-speech-recognition=(self)\r\n"
         "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'\r\n\r\n",
        (long)status, reason, type, (unsigned long)body.length];
    NSData *head = [headers dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *parts[] = { head.bytes, body.bytes };
    size_t sizes[] = { head.length, body.length };
    struct timespec deadline; clock_gettime(CLOCK_MONOTONIC, &deadline); deadline.tv_sec += 3;
    for (size_t i = 0; i < 2; i++) {
        size_t offset = 0;
        while (offset < sizes[i]) {
            struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
            int remaining = (int)((deadline.tv_sec - now.tv_sec) * 1000 + (deadline.tv_nsec - now.tv_nsec) / 1000000);
            if (remaining <= 0) return;
            struct pollfd wait = { .fd = fd, .events = POLLOUT };
            if (poll(&wait, 1, remaining) <= 0) return;
            ssize_t n = send(fd, parts[i] + offset, sizes[i] - offset, MSG_DONTWAIT);
            if (n < 0) { if (errno == EINTR) continue; return; }
            if (n == 0) return;
            offset += (size_t)n;
        }
    }
}

- (void)json:(int)fd status:(NSInteger)status object:(id)object {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object ?: @{} options:NSJSONWritingFragmentsAllowed error:nil] ?: [NSData data];
    [self respond:fd status:status type:@"application/json; charset=utf-8" body:data];
}

- (BOOL)pairingAllowedForPeer:(NSString *)peer generation:(uint64_t)generation code:(NSString *)code
                         deviceID:(NSString *)deviceID deviceName:(NSString *)deviceName token:(NSString **)token {
    if (deviceID.length != 32 || ![deviceID canBeConvertedToEncoding:NSASCIIStringEncoding]) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    if ([deviceID rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound) return NO;
    // Device IDs are hex identifiers; normalize case so one physical client
    // cannot consume multiple pairing slots with upper/lowercase variants.
    deviceID = deviceID.lowercaseString;
    __block BOOL accepted = NO;
    __block NSString *pairedToken = nil;
    dispatch_sync(self.queue, ^{
        if (!self.active || self.generation != generation || [NSDate.date timeIntervalSinceDate:self.startedAt] > 600) return;
        NSDictionary *attempt = self.pairAttempts[peer];
        NSDate *window = attempt[@"window"];
        NSUInteger count = [attempt[@"count"] unsignedIntegerValue];
        if (!window || [NSDate.date timeIntervalSinceDate:window] >= 60) { window = NSDate.date; count = 0; }
        if (count >= 10) { self.pairAttempts[peer] = @{@"window":window, @"count":@(count)}; return; }
        if (![code isEqualToString:self.pairingCode]) {
            self.pairAttempts[peer] = @{@"window":window, @"count":@(count + 1)};
            return;
        }
        NSDictionary *existing = self.devicesByID[deviceID];
        if (existing) { pairedToken = existing[@"token"]; accepted = YES; return; }
        if (self.devicesByID.count >= 4) return;
        NSString *newToken = MicaRandomToken();
        if (!newToken) return;
        NSString *safeName = [[deviceName componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@""];
        if (safeName.length > 40) safeName = [safeName substringToIndex:40];
        self.devicesByID[deviceID] = @{@"token":newToken, @"name":safeName.length ? safeName : @"Android device"};
        pairedToken = newToken;
        accepted = YES;
    });
    if (accepted) *token = pairedToken;
    return accepted;
}

- (void)handleClient:(int)fd peer:(NSString *)peer expectedHost:(NSString *)expectedHost generation:(uint64_t)generation {
    @autoreleasepool {
        @try {
            uint8_t chunk[4096]; NSMutableData *buffer = [NSMutableData data];
            NSUInteger headerEnd = NSNotFound, contentLength = 0;
            struct timespec deadline; clock_gettime(CLOCK_MONOTONIC, &deadline); deadline.tv_sec += 5;
            while (buffer.length <= kRemoteRequestLimit) {
                struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
                int remaining = (int)((deadline.tv_sec - now.tv_sec) * 1000 + (deadline.tv_nsec - now.tv_nsec) / 1000000);
                if (remaining <= 0) break;
                struct pollfd wait = { .fd = fd, .events = POLLIN };
                if (poll(&wait, 1, remaining) <= 0) break;
                ssize_t count = recv(fd, chunk, sizeof(chunk), 0);
                if (count <= 0) break;
                [buffer appendBytes:chunk length:(NSUInteger)count];
                const uint8_t *p = buffer.bytes;
                for (NSUInteger i = 0; i + 3 < buffer.length; i++)
                    if (p[i] == '\r' && p[i+1] == '\n' && p[i+2] == '\r' && p[i+3] == '\n') { headerEnd = i + 4; break; }
                if (headerEnd != NSNotFound) {
                    if (headerEnd > 8192) break;
                    NSString *header = [[NSString alloc] initWithBytes:p length:headerEnd encoding:NSUTF8StringEncoding];
                    for (NSString *line in [header componentsSeparatedByString:@"\r\n"]) {
                        if (![line.lowercaseString hasPrefix:@"content-length:"]) continue;
                        NSString *raw = [[line substringFromIndex:15] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                        NSScanner *scanner = [NSScanner scannerWithString:raw]; unsigned long long value = 0;
                        if (![scanner scanUnsignedLongLong:&value] || !scanner.isAtEnd || value > kRemoteRequestLimit) { contentLength = kRemoteRequestLimit + 1; break; }
                        contentLength = (NSUInteger)value;
                    }
                    if (contentLength > kRemoteRequestLimit || buffer.length >= headerEnd + contentLength) break;
                }
            }
            if (contentLength > kRemoteRequestLimit) { [self respond:fd status:413 type:@"text/plain" body:NSData.data]; return; }
            if (headerEnd == NSNotFound || buffer.length < headerEnd + contentLength) { [self respond:fd status:400 type:@"text/plain" body:NSData.data]; return; }
            NSString *header = [[NSString alloc] initWithBytes:buffer.bytes length:headerEnd encoding:NSUTF8StringEncoding];
            NSArray *lines = [header componentsSeparatedByString:@"\r\n"];
            NSArray *request = [lines.firstObject componentsSeparatedByString:@" "];
            if (request.count < 2) { [self respond:fd status:400 type:@"text/plain" body:NSData.data]; return; }
            NSString *method = request[0], *path = request[1], *authorization = @"", *hostHeader = @"", *origin = @"";
            for (NSString *line in lines) {
                if ([line.lowercaseString hasPrefix:@"authorization:"])
                    authorization = [[line substringFromIndex:14] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                else if ([line.lowercaseString hasPrefix:@"host:"])
                    hostHeader = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                else if ([line.lowercaseString hasPrefix:@"origin:"])
                    origin = [[line substringFromIndex:7] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            }
            BOOL validHost = [hostHeader caseInsensitiveCompare:expectedHost] == NSOrderedSame ||
                (getenv("MICA_REMOTE_TEST_MODE") && ([hostHeader caseInsensitiveCompare:@"localhost:8765"] == NSOrderedSame ||
                 [hostHeader caseInsensitiveCompare:@"localhost"] == NSOrderedSame));
            BOOL validOrigin = !origin.length || [origin caseInsensitiveCompare:[NSString stringWithFormat:@"https://%@", expectedHost]] == NSOrderedSame ||
                (getenv("MICA_REMOTE_TEST_MODE") && [origin caseInsensitiveCompare:[NSString stringWithFormat:@"http://%@", expectedHost]] == NSOrderedSame) ||
                (getenv("MICA_REMOTE_TEST_MODE") && [origin caseInsensitiveCompare:@"http://localhost:8765"] == NSOrderedSame);
            if (!validHost || !validOrigin) { [self json:fd status:403 object:@{@"error":@"invalid host or origin"}]; return; }
            NSData *body = [buffer subdataWithRange:NSMakeRange(headerEnd, contentLength)];
            NSDictionary *json = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : @{};
            if (![json isKindOfClass:NSDictionary.class]) json = @{};

            if ([method isEqualToString:@"GET"] && ([path isEqualToString:@"/"] || [path hasPrefix:@"/?code="])) {
                [self respond:fd status:200 type:@"text/html; charset=utf-8" body:[self remotePageData]];
                return;
            }
            if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/pair"]) {
                NSString *token = nil;
                NSString *code = [json[@"code"] isKindOfClass:NSString.class] ? json[@"code"] : @"";
                NSString *deviceID = [json[@"deviceID"] isKindOfClass:NSString.class] ? json[@"deviceID"] : @"";
                NSString *deviceName = [json[@"deviceName"] isKindOfClass:NSString.class] ? json[@"deviceName"] : @"Android device";
                BOOL paired = [self pairingAllowedForPeer:peer generation:generation code:code
                    deviceID:deviceID deviceName:deviceName token:&token];
                if (!paired) { [self json:fd status:401 object:@{@"error":@"pairing code invalid, expired, or attempt limit reached"}]; return; }
                [self json:fd status:200 object:@{@"token":token ?: @""}]; return;
            }

            NSString *token = [authorization hasPrefix:@"Bearer "] ? [authorization substringFromIndex:7] : @"";
            __block BOOL validToken = NO;
            dispatch_sync(self.queue, ^{
                if (!self.active || self.generation != generation) return;
                for (NSDictionary *device in self.devicesByID.allValues)
                    if ([device[@"token"] isEqualToString:token]) { validToken = YES; break; }
            });
            if (!validToken) { [self json:fd status:401 object:@{@"error":@"pairing required"}]; return; }

            if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/revoke"]) {
                NSString *deviceID = [json[@"deviceID"] isKindOfClass:NSString.class] ? json[@"deviceID"] : @"";
                __block BOOL revoked = NO;
                dispatch_sync(self.queue, ^{
                    if (self.active && self.generation == generation && self.devicesByID[deviceID]) {
                        [self.devicesByID removeObjectForKey:deviceID]; revoked = YES;
                    }
                });
                if (!revoked) { [self json:fd status:404 object:@{@"error":@"device not found"}]; return; }
                [self json:fd status:200 object:@{@"ok":@YES}]; return;
            }
            if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/state"]) {
                __block NSDictionary *state = nil;
                [self performMainActionForGeneration:generation action:^{ state = self.snapshot ? self.snapshot() : @{}; }];
                if (!state) { [self json:fd status:401 object:@{@"error":@"service stopped"}]; return; }
                NSMutableArray *projects = [NSMutableArray array];
                for (NSDictionary *project in state[@"projects"]) {
                    NSMutableArray *tabs = [NSMutableArray array];
                    for (NSDictionary *tab in project[@"tabs"]) { NSMutableDictionary *small = [tab mutableCopy]; [small removeObjectForKey:@"screen"]; [tabs addObject:small]; }
                    [projects addObject:@{@"name":project[@"name"] ?: @"Mica", @"tabs":tabs}];
                }
                __block NSUInteger count = 0; dispatch_sync(self.queue, ^{ if (self.active && self.generation == generation) count = self.devicesByID.count; });
                [self json:fd status:200 object:@{@"name":@"Mica", @"devices":@(count), @"projects":projects}]; return;
            }
            if ([method isEqualToString:@"GET"] && [path hasPrefix:@"/api/screen?id="]) {
                NSString *identifier = [[path substringFromIndex:15] stringByRemovingPercentEncoding]; __block NSString *screen = nil;
                [self performMainActionForGeneration:generation action:^{ screen = self.screenSnapshot ? self.screenSnapshot(identifier) : nil; }];
                if (!screen) { [self json:fd status:404 object:@{@"error":@"tab unavailable"}]; return; }
                [self json:fd status:200 object:@{@"text":screen}]; return;
            }
            if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/select"]) {
                NSString *identifier = [json[@"id"] isKindOfClass:NSString.class] ? json[@"id"] : @""; __block BOOL selected = NO;
                [self performMainActionForGeneration:generation action:^{ selected = self.selectTab ? self.selectTab(identifier) : NO; }];
                [self json:fd status:selected ? 200 : 404 object:@{@"ok":@(selected)}]; return;
            }
            if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/input"]) {
                NSString *identifier = [json[@"id"] isKindOfClass:NSString.class] ? json[@"id"] : @"";
                NSString *text = [json[@"text"] isKindOfClass:NSString.class] ? json[@"text"] : @"";
                NSData *encoded = [text dataUsingEncoding:NSUTF8StringEncoding];
                if (!identifier.length || !text.length || encoded.length > 8192) { [self json:fd status:400 object:@{@"error":@"invalid input"}]; return; }
                __block BOOL accepted = NO;
                [self performMainActionForGeneration:generation action:^{ accepted = self.sendText ? self.sendText(identifier, text) : NO; }];
                [self json:fd status:accepted ? 200 : 404 object:@{@"ok":@(accepted)}]; return;
            }
            if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/devices"]) {
                __block NSMutableArray *devices = [NSMutableArray array];
                dispatch_sync(self.queue, ^{
                    if (self.active && self.generation == generation) for (NSString *deviceID in self.devicesByID)
                        [devices addObject:@{@"id":deviceID, @"name":self.devicesByID[deviceID][@"name"] ?: @"Android device"}];
                });
                [self json:fd status:200 object:@{@"devices":devices}]; return;
            }
            [self json:fd status:404 object:@{@"error":@"not found"}];
        } @catch (__unused NSException *exception) {
            [self respond:fd status:500 type:@"text/plain" body:NSData.data];
        } @finally {
            close(fd);
            dispatch_sync(self.queue, ^{
                NSNumber *key = @(fd);
                if ([self.clientFDs[key] unsignedLongLongValue] == generation) {
                    [self.clientFDs removeObjectForKey:key];
                    if (self.clients) self.clients--;
                }
            });
        }
    }
}

- (NSString *)renewPairingCode {
    NSAssert(NSThread.isMainThread, @"Pairing code changes are main-thread confined");
    if (!self.isRunning) return nil;
    NSString *code = MicaRandomPairingCode();
    if (!code) return nil;
    dispatch_sync(self.queue, ^{
        if (!self.active) return;
        self.pairingCode = code;
        self.startedAt = NSDate.date;
        [self.pairAttempts removeAllObjects];
        if (self.tlsListener && self.certificateData.length) {
            uint8_t digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(self.certificateData.bytes, (CC_LONG)self.certificateData.length, digest);
            NSMutableString *pin = [NSMutableString stringWithCapacity:64]; for (NSUInteger i = 0; i < sizeof(digest); i++) [pin appendFormat:@"%02x", digest[i]];
            NSString *host = [NSURL URLWithString:self.localURL].host ?: @"";
            self.pairingPayload = [NSString stringWithFormat:@"mica://pair?host=%@&port=8765&pin=%@&code=%@", host, pin, code];
        }
    });
    return code;
}

- (void)stop {
    NSAssert(NSThread.isMainThread, @"Mica remote lifecycle is main-thread confined");
    if (!self.source && !self.tlsListener) return;
    if (self.tlsListener) { nw_listener_cancel(self.tlsListener); self.tlsListener = nil; }
    if (self.pathMonitor) { nw_path_monitor_cancel(self.pathMonitor); self.pathMonitor = nil; }
    [self.bonjour stop]; self.bonjour = nil;
    dispatch_source_t source = self.source; self.source = nil;
    int listener = self.fd; self.fd = -1;
    if (source) dispatch_source_cancel(source);
    if (listener >= 0) { shutdown(listener, SHUT_RDWR); close(listener); }
    dispatch_sync(self.queue, ^{
        self.generation++; self.active = NO; self.tlsClients = 0;
        for (NSNumber *number in self.clientFDs) shutdown(number.intValue, SHUT_RDWR);
        [self.clientFDs removeAllObjects]; self.clients = 0;
        [self.devicesByID removeAllObjects]; [self.pairAttempts removeAllObjects];
    });
    self.pairingCode = nil; self.localURL = nil; self.startedAt = nil; self.boundAddress = nil;
    self.pairingPayload = nil; self.certificateData = nil;
}

- (void)dealloc { if (NSThread.isMainThread) [self stop]; }
@end
