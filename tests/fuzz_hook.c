#include "mica_hook.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char **argv){uint32_t x=argc>1?(uint32_t)strtoul(argv[1],0,10):1;unsigned char b[MICA_HOOK_LINE_MAX+1];MicaHookEvent e;
 for(unsigned run=0;run<10000;run++){size_t n=x%sizeof(b);for(size_t i=0;i<n;i++){x^=x<<13;x^=x>>17;x^=x<<5;b[i]=(unsigned char)x;}mica_hook_parse((const char*)b,n,&e);}
 printf("hook fuzz seed %u passed\n",argc>1?(unsigned)strtoul(argv[1],0,10):1);return 0;}
