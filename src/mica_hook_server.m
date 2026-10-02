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
@end
@implementation MicaHookServer
+ (instancetype)sharedServer { static MicaHookServer *s; static dispatch_once_t once; dispatch_once(&once, ^{ s=[self new]; s.fd=-1; }); return s; }
- (BOOL)startAtPath:(NSString *)path {
    if (_acceptSource) return YES;
    NSString *chosen=path;
    if (!chosen.length) chosen=[[[NSProcessInfo processInfo] environment] objectForKey:@"MICA_HOOK_SOCK"];
    if (!chosen.length) chosen=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Mica/hooks.sock"];
    NSString *dir=[chosen stringByDeletingLastPathComponent];
    NSError *directoryError=nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:&directoryError]) return NO;
    chmod(dir.fileSystemRepresentation,0700); unlink(chosen.fileSystemRepresentation);
    int fd=socket(AF_UNIX,SOCK_STREAM,0); if(fd<0)return NO;
    struct sockaddr_un addr={0}; addr.sun_family=AF_UNIX;
    if(chosen.length>=sizeof(addr.sun_path)){close(fd);return NO;}
    strlcpy(addr.sun_path,chosen.fileSystemRepresentation,sizeof(addr.sun_path));
    if(bind(fd,(struct sockaddr*)&addr,sizeof(addr))<0){close(fd);return NO;}
    chmod(chosen.fileSystemRepresentation,0600);
    if(listen(fd,16)<0){close(fd);unlink(chosen.fileSystemRepresentation);return NO;}
    fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK); _fd=fd; _socketPath=[chosen copy];
    _acceptSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    __weak typeof(self) weak=self;
    dispatch_source_set_event_handler(_acceptSource, ^{ typeof(self) self=weak; if(!self)return; for(;;){int c=accept(self.fd,NULL,NULL);if(c<0){if(errno==EINTR)continue;break;} [self readClient:c];} });
    dispatch_source_set_cancel_handler(_acceptSource, ^{ close(fd); }); dispatch_resume(_acceptSource); return YES;
}
- (void)readClient:(int)fd {
    dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    NSMutableData *buffer=[NSMutableData data]; __block NSUInteger lines=0; __weak typeof(self) weak=self;
    dispatch_source_set_event_handler(source, ^{ typeof(self) self=weak; if(!self){close(fd);dispatch_source_cancel(source);return;}
        char bytes[4096]; ssize_t n=read(fd,bytes,sizeof(bytes)); if(n<=0){dispatch_source_cancel(source);return;}
        [buffer appendBytes:bytes length:(NSUInteger)n]; const uint8_t *p=buffer.bytes; NSUInteger start=0;
        for(NSUInteger i=0;i<buffer.length;i++) if(p[i]=='\n') { NSUInteger len=i-start; MicaHookEvent event;
            if(++lines>64 || len>MICA_HOOK_LINE_MAX || !mica_hook_parse((const char*)p+start,len,&event)){dispatch_source_cancel(source);return;}
            MicaHookDelivery delivery=self.delivery; if(delivery)dispatch_async(dispatch_get_main_queue(),^{delivery(event);}); start=i+1;
        }
        if(start){[buffer replaceBytesInRange:NSMakeRange(0,start) withBytes:NULL length:0];}
        if(buffer.length>MICA_HOOK_LINE_MAX)dispatch_source_cancel(source);
    });
    dispatch_source_set_cancel_handler(source, ^{close(fd);}); dispatch_resume(source);
}
- (void)stop { if(!_acceptSource)return; dispatch_source_cancel(_acceptSource); _acceptSource=nil; _fd=-1; if(_socketPath)unlink(_socketPath.fileSystemRepresentation); _socketPath=nil; }
- (void)dealloc { [self stop]; }
@end
