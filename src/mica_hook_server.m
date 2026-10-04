#import "mica_hook_server.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <sys/stat.h>

@interface MicaHookServer ()
@property(nonatomic, copy, readwrite) NSString *socketPath;
@property(nonatomic) int fd;
@property(nonatomic) dispatch_source_t acceptSource;
@property(nonatomic, strong) NSLock *clientLock;
@property(nonatomic) NSUInteger activeClients;
@property(nonatomic) dev_t socketDevice;
@property(nonatomic) ino_t socketInode;
@end
@implementation MicaHookServer
+ (instancetype)sharedServer { static MicaHookServer *s; static dispatch_once_t once; dispatch_once(&once, ^{ s=[self new]; }); return s; }
- (instancetype)init {
    self=[super init];
    if(self){_fd=-1;_clientLock=[NSLock new];}
    return self;
}
- (BOOL)startAtPath:(NSString *)path {
    if (_acceptSource) return YES;
    NSString *chosen=path;
    if (!chosen.length) chosen=[[[NSProcessInfo processInfo] environment] objectForKey:@"MICA_HOOK_SOCK"];
    BOOL defaultPath = !chosen.length;
    if (defaultPath) chosen=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Mica/hooks.sock"];
    if (![chosen isAbsolutePath] || chosen.fileSystemRepresentation == NULL) return NO;
    struct sockaddr_un addr={0};
    if (strlen(chosen.fileSystemRepresentation) >= sizeof(addr.sun_path)) return NO;
    NSString *dir=[chosen stringByDeletingLastPathComponent];
    NSError *directoryError=nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:&directoryError]) return NO;
    struct stat dirStat;
    if (lstat(dir.fileSystemRepresentation, &dirStat) != 0 || !S_ISDIR(dirStat.st_mode) ||
        dirStat.st_uid != getuid()) return NO;
    if (defaultPath && (dirStat.st_mode & 077) != 0) {
        if (chmod(dir.fileSystemRepresentation,0700) != 0 || lstat(dir.fileSystemRepresentation,&dirStat) != 0 ||
            !S_ISDIR(dirStat.st_mode) || dirStat.st_uid != getuid() || (dirStat.st_mode & 077) != 0) return NO;
    } else if ((dirStat.st_mode & 077) != 0) return NO;

    // Never remove a regular file or another user's socket. A live listener owns the path;
    // only an unreachable socket owned by this user is safe to clean up as stale.
    struct stat existing;
    if (lstat(chosen.fileSystemRepresentation, &existing) == 0) {
        if (!S_ISSOCK(existing.st_mode) || existing.st_uid != getuid()) return NO;
        int probe=socket(AF_UNIX,SOCK_STREAM,0); if(probe<0)return NO;
        addr.sun_family=AF_UNIX;
        strlcpy(addr.sun_path,chosen.fileSystemRepresentation,sizeof(addr.sun_path));
        int connected=connect(probe,(struct sockaddr*)&addr,sizeof(addr));
        int connectError=errno;
        close(probe);
        if (connected == 0 || (connectError != ECONNREFUSED && connectError != ENOENT)) return NO;
        struct stat current;
        if (lstat(chosen.fileSystemRepresentation,&current) != 0 || current.st_dev != existing.st_dev ||
            current.st_ino != existing.st_ino || !S_ISSOCK(current.st_mode) || current.st_uid != getuid() ||
            unlink(chosen.fileSystemRepresentation) != 0) return NO;
    } else if (errno != ENOENT) return NO;
    int fd=socket(AF_UNIX,SOCK_STREAM,0); if(fd<0)return NO;
    addr.sun_family=AF_UNIX;
    strlcpy(addr.sun_path,chosen.fileSystemRepresentation,sizeof(addr.sun_path));
    if(bind(fd,(struct sockaddr*)&addr,sizeof(addr))<0){close(fd);return NO;}
    if(chmod(chosen.fileSystemRepresentation,0600)!=0){close(fd);unlink(chosen.fileSystemRepresentation);return NO;}
    if(listen(fd,16)<0){close(fd);unlink(chosen.fileSystemRepresentation);return NO;}
    struct stat socketStat;
    if(lstat(chosen.fileSystemRepresentation,&socketStat)!=0 || !S_ISSOCK(socketStat.st_mode) ||
        socketStat.st_uid!=getuid()){close(fd);unlink(chosen.fileSystemRepresentation);return NO;}
    _socketDevice=socketStat.st_dev; _socketInode=socketStat.st_ino;
    fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK); _fd=fd; _socketPath=[chosen copy];
    _acceptSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    __weak typeof(self) weak=self;
    dispatch_source_set_event_handler(_acceptSource, ^{ typeof(self) self=weak; if(!self)return; for(;;){int c=accept(self.fd,NULL,NULL);if(c<0){if(errno==EINTR)continue;break;} [self.clientLock lock]; BOOL allowed=self.activeClients<32; if(allowed)self.activeClients++; [self.clientLock unlock]; if(allowed)[self readClient:c];else close(c);} });
    dispatch_source_set_cancel_handler(_acceptSource, ^{ close(fd); }); dispatch_resume(_acceptSource); return YES;
}
- (void)readClient:(int)fd {
    dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    NSMutableData *buffer=[NSMutableData data]; __block NSUInteger lines=0; __weak typeof(self) weak=self;
    dispatch_source_set_event_handler(source, ^{ typeof(self) self=weak; if(!self){dispatch_source_cancel(source);return;}
        char bytes[4096]; ssize_t n=read(fd,bytes,sizeof(bytes)); if(n<=0){dispatch_source_cancel(source);return;}
        [buffer appendBytes:bytes length:(NSUInteger)n]; const uint8_t *p=buffer.bytes; NSUInteger start=0;
        for(NSUInteger i=0;i<buffer.length;i++) if(p[i]=='\n') { NSUInteger len=i-start; MicaHookEvent event;
            if(++lines>64 || len>MICA_HOOK_LINE_MAX || !mica_hook_parse((const char*)p+start,len,&event)){dispatch_source_cancel(source);return;}
            MicaHookDelivery delivery=self.delivery; if(delivery)dispatch_async(dispatch_get_main_queue(),^{delivery(event);}); start=i+1;
        }
        if(start){[buffer replaceBytesInRange:NSMakeRange(0,start) withBytes:NULL length:0];}
        if(buffer.length>MICA_HOOK_LINE_MAX)dispatch_source_cancel(source);
    });
    dispatch_source_set_cancel_handler(source, ^{close(fd); typeof(self) self=weak; if(self){[self.clientLock lock]; if(self.activeClients)self.activeClients--; [self.clientLock unlock];} }); dispatch_resume(source);
}
- (void)stop {
    if(!_acceptSource)return;
    dispatch_source_cancel(_acceptSource); _acceptSource=nil; _fd=-1;
    if(_socketPath){struct stat current;if(lstat(_socketPath.fileSystemRepresentation,&current)==0 &&
        S_ISSOCK(current.st_mode) && current.st_dev==_socketDevice && current.st_ino==_socketInode)
        unlink(_socketPath.fileSystemRepresentation);}
    _socketPath=nil; _socketDevice=0; _socketInode=0;
}
- (void)dealloc { [self stop]; }
@end
