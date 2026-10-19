#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>
#import "../src/mica_remote_server.h"

@interface MicaRemoteServer (TestTLSBridge)
- (NSData *)bridgeRequestData:(NSData *)request peer:(NSString *)peer expectedHost:(NSString *)expectedHost generation:(uint64_t)generation;
@end

static NSString *Request(NSString *method, NSString *path, NSString *token, NSDictionary *object) {
    int fd=socket(AF_INET,SOCK_STREAM,0);if(fd<0)return nil;
    struct sockaddr_in addr={0};addr.sin_family=AF_INET;addr.sin_port=htons(8765);inet_pton(AF_INET,"127.0.0.1",&addr.sin_addr);
    if(connect(fd,(struct sockaddr *)&addr,sizeof(addr))!=0){close(fd);return nil;}
    NSData *body=object?[NSJSONSerialization dataWithJSONObject:object options:0 error:nil]:[NSData data];
    NSMutableString *head=[NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n",method,path];
    if(token.length)[head appendFormat:@"Authorization: Bearer %@\r\n",token];
    if(object)[head appendFormat:@"Content-Type: application/json\r\nContent-Length: %lu\r\n",(unsigned long)body.length];
    [head appendString:@"\r\n"];NSData *header=[head dataUsingEncoding:NSUTF8StringEncoding];write(fd,header.bytes,header.length);if(body.length)write(fd,body.bytes,body.length);
    NSMutableData *response=[NSMutableData data];uint8_t chunk[4096];ssize_t n;while((n=read(fd,chunk,sizeof(chunk)))>0)[response appendBytes:chunk length:(NSUInteger)n];close(fd);
    return [[NSString alloc]initWithData:response encoding:NSUTF8StringEncoding];
}

static NSString *AsyncRequest(NSString *method, NSString *path, NSString *token, NSDictionary *object) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSString *response=nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{response=Request(method,path,token,object);dispatch_semaphore_signal(done);});
    while(dispatch_semaphore_wait(done,DISPATCH_TIME_NOW)!=0) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.02,true);
    return response;
}

static NSInteger Status(NSString *response) { return [[[response componentsSeparatedByString:@" "] objectAtIndex:1] integerValue]; }
static NSDictionary *JSONBody(NSString *response) {
    NSRange divider=[response rangeOfString:@"\r\n\r\n"];if(divider.location==NSNotFound)return @{};
    NSData *body=[[response substringFromIndex:NSMaxRange(divider)] dataUsingEncoding:NSUTF8StringEncoding];
    id value=[NSJSONSerialization JSONObjectWithData:body options:0 error:nil];return [value isKindOfClass:NSDictionary.class]?value:@{};
}

int main(void) { @autoreleasepool {
    setenv("MICA_REMOTE_TEST_MODE","1",1);
    MicaRemoteServer *server=MicaRemoteServer.sharedServer;
    server.snapshot=^{
        NSDictionary *tab=@{@"id":@"tab-1", @"name":@"Shell", @"running":@(YES), @"screen":@"ready> "};
        NSDictionary *project=@{@"name":@"Test Project", @"tabs":@[tab]};
        return @{@"projects":@[project]};
    };
    server.screenSnapshot=^NSString *(NSString *tabID){return [tabID isEqualToString:@"tab-1"]?@"ready> ":nil;};
    server.selectTab=^BOOL(NSString *tabID){return [tabID isEqualToString:@"tab-1"];};
    __block NSString *received=nil;server.sendText=^BOOL(NSString *tabID,NSString *text){if(![tabID isEqualToString:@"tab-1"])return NO;received=text;return YES;};
    if(![server start]){fprintf(stderr,"FAIL: start local listener\n");return 1;}
    NSString *page=AsyncRequest(@"GET",@"/",nil,nil);if(!page||Status(page)!=200||![page containsString:@"Mica Remote"]){fprintf(stderr,"FAIL: local mobile page (%ld)\n%s\n",(long)Status(page),page.UTF8String?:"<nil>");return 1;}
    NSString *bridgeRequest=@"GET / HTTP/1.1\r\nHost: localhost:8765\r\nConnection: close\r\n\r\n";
    NSData *bridgeResponse=[server bridgeRequestData:[bridgeRequest dataUsingEncoding:NSUTF8StringEncoding] peer:@"127.0.0.1" expectedHost:@"localhost:8765" generation:[[server valueForKey:@"generation"] unsignedLongLongValue]];
    NSString *bridgedPage=[[NSString alloc]initWithData:bridgeResponse encoding:NSISOLatin1StringEncoding];
    if(![bridgedPage containsString:@"HTTP/1.1 200 OK"]||![bridgedPage containsString:@"Mica Remote"]||bridgeResponse.length<9000){fprintf(stderr,"FAIL: TLS socket bridge returns complete large page (%lu bytes)\n",(unsigned long)bridgeResponse.length);return 1;}
    if(Status(AsyncRequest(@"GET",@"/api/state",nil,nil))!=401){fprintf(stderr,"FAIL: unauthenticated inventory\n");return 1;}
    NSString *deviceID=@"00112233445566778899aabbccddeeff";
    NSDictionary *pairRequest=@{@"code":server.pairingCode,@"deviceID":deviceID,@"deviceName":@"Test Android"};
    NSString *wrong=AsyncRequest(@"POST",@"/api/pair",nil,@{@"code":@"000000",@"deviceID":deviceID});if(Status(wrong)!=401){fprintf(stderr,"FAIL: reject incorrect pairing code\n%s\n",wrong.UTF8String?:"<nil>");return 1;}
    for(NSUInteger i=1;i<10;i++)if(Status(AsyncRequest(@"POST",@"/api/pair",nil,@{@"code":@"000000",@"deviceID":deviceID}))!=401){fprintf(stderr,"FAIL: reject incorrect code attempt %lu\n",(unsigned long)i+1);return 1;}
    if(Status(AsyncRequest(@"POST",@"/api/pair",nil,pairRequest))!=401){fprintf(stderr,"FAIL: throttle repeated pairing attempts\n");return 1;}
    if(![server renewPairingCode]){fprintf(stderr,"FAIL: renew pairing code\n");return 1;}
    pairRequest=@{@"code":server.pairingCode,@"deviceID":deviceID,@"deviceName":@"Test Android"};
    NSString *pair=AsyncRequest(@"POST",@"/api/pair",nil,pairRequest);if(Status(pair)!=200){fprintf(stderr,"FAIL: pair device\n%s\n",pair.UTF8String?:"<nil>");return 1;}
    NSString *token=JSONBody(pair)[@"token"];
    NSString *repeat=AsyncRequest(@"POST",@"/api/pair",nil,pairRequest);if(Status(repeat)!=200||![JSONBody(repeat)[@"token"] isEqualToString:token]){fprintf(stderr,"FAIL: repeated scans reuse paired device token\n");return 1;}
    NSMutableDictionary *caseVariant=[pairRequest mutableCopy];caseVariant[@"deviceID"]=[deviceID uppercaseString];
    NSString *caseRepeat=AsyncRequest(@"POST",@"/api/pair",nil,caseVariant);if(Status(caseRepeat)!=200||![JSONBody(caseRepeat)[@"token"] isEqualToString:token]){fprintf(stderr,"FAIL: device identity is case-insensitive\n");return 1;}
    for(NSUInteger i=1;i<4;i++){
        NSString *extraID=[NSString stringWithFormat:@"%032lx",(unsigned long)i];
        NSDictionary *extra=@{@"code":server.pairingCode,@"deviceID":extraID,@"deviceName":@"Extra device"};
        if(Status(AsyncRequest(@"POST",@"/api/pair",nil,extra))!=200){fprintf(stderr,"FAIL: pair allowed device %lu\n",(unsigned long)i+1);return 1;}
    }
    NSDictionary *fifth=@{@"code":server.pairingCode,@"deviceID":@"ffeeddccbbaa99887766554433221100",@"deviceName":@"Fifth device"};
    if(Status(AsyncRequest(@"POST",@"/api/pair",nil,fifth))!=401){fprintf(stderr,"FAIL: enforce four paired device limit\n");return 1;}
    NSString *state=AsyncRequest(@"GET",@"/api/state",token,nil);if(Status(state)!=200||![state containsString:@"Test Project"]||[state containsString:@"ready>"]){fprintf(stderr,"FAIL: authenticated bounded inventory\n");return 1;}
    NSString *screen=AsyncRequest(@"GET",@"/api/screen?id=tab-1",token,nil);NSDictionary *screenBody=JSONBody(screen);if(Status(screen)!=200||![screenBody[@"text"] isEqualToString:@"ready> "]){fprintf(stderr,"FAIL: selected screen snapshot\n");return 1;}
    if(Status(AsyncRequest(@"POST",@"/api/select",token,@{@"id":@"tab-1"}))!=200){fprintf(stderr,"FAIL: select tab\n");return 1;}
    if(Status(AsyncRequest(@"POST",@"/api/input",token,@{@"id":@"tab-1",@"text":@"hello"}))!=200||![received isEqualToString:@"hello"]){fprintf(stderr,"FAIL: send text\n");return 1;}
    if(Status(AsyncRequest(@"POST",@"/api/revoke",token,@{@"deviceID":deviceID}))!=200||Status(AsyncRequest(@"GET",@"/api/state",token,nil))!=401){fprintf(stderr,"FAIL: device revocation invalidates token\n");return 1;}
    NSString *oldToken=token;
    [server stop];if(server.isRunning||server.localURL){fprintf(stderr,"FAIL: stop listener\n");return 1;}
    if(![server start]||Status(AsyncRequest(@"GET",@"/api/state",oldToken,nil))!=401){fprintf(stderr,"FAIL: restart revokes old tokens\n");return 1;}
    [server stop];
    unsetenv("MICA_REMOTE_TEST_MODE");puts("PASS: remote pairing, auth, inventory, screen, selection, input and revocation");return 0;
} }
