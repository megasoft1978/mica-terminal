#import "mica_hook_server.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>
#import <assert.h>

int main(void) {
    @autoreleasepool {
        NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert(mkdir(dir.fileSystemRepresentation,0700)==0);
        NSString *path=[dir stringByAppendingPathComponent:@"hooks.sock"];
        MicaHookServer *server=[MicaHookServer new]; __block BOOL delivered=NO;
        server.delivery=^(MicaHookEvent event){delivered=!strcmp(event.event,"Stop");};
        assert([server startAtPath:path]); struct stat st; assert(stat(dir.fileSystemRepresentation,&st)==0 && (st.st_mode&0777)==0700);
        assert(stat(path.fileSystemRepresentation,&st)==0 && (st.st_mode&0777)==0600);
        int fd=socket(AF_UNIX,SOCK_STREAM,0); struct sockaddr_un addr={0}; addr.sun_family=AF_UNIX; strlcpy(addr.sun_path,path.fileSystemRepresentation,sizeof(addr.sun_path)); assert(connect(fd,(struct sockaddr*)&addr,sizeof(addr))==0);
        const char *line="{\"token\":\"0123456789abcdef0123456789abcdef\",\"event\":\"Stop\",\"agent\":\"claude\"}\n"; assert(write(fd,line,strlen(line))==(ssize_t)strlen(line)); close(fd);
        for(int i=0;i<100&&!delivered;i++) { [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]]; }
        assert(delivered); [server stop]; assert(access(path.fileSystemRepresentation,F_OK)!=0); rmdir(dir.fileSystemRepresentation);
        puts("hook socket delivery and 0700/0600 permissions passed");
    }
}
