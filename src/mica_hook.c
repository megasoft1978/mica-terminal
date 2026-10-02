#include "mica_hook.h"
#include <ctype.h>
#include <stdint.h>
#include <string.h>

typedef struct { const unsigned char *p, *end; unsigned depth; } Parser;
static void ws(Parser *p) { while (p->p < p->end && (*p->p==' '||*p->p=='\t'||*p->p=='\r'||*p->p=='\n')) p->p++; }
static bool utf8(const unsigned char *s, size_t n) {
    for (size_t i=0;i<n;) { unsigned c=s[i++]; if(c<128) continue; unsigned need; uint32_t v;
        if(c>=0xc2&&c<=0xdf){need=1;v=c&31;} else if(c>=0xe0&&c<=0xef){need=2;v=c&15;} else if(c>=0xf0&&c<=0xf4){need=3;v=c&7;} else return false;
        if(i+need>n)return false; for(unsigned j=0;j<need;j++){unsigned d=s[i++];if((d&0xc0)!=0x80)return false;v=(v<<6)|(d&63);}
        if((need==1&&v<0x80)||(need==2&&v<0x800)||(need==3&&v<0x10000)||v>0x10ffff||(v>=0xd800&&v<=0xdfff))return false;
    } return true;
}
static bool string(Parser *p, char *out, size_t cap) {
    if(p->p==p->end||*p->p++!='"')return false; size_t n=0;
    while(p->p<p->end&&*p->p!='"') { unsigned char c=*p->p++;
        if(c<0x20)return false;
        if(c=='\\') { if(p->p==p->end)return false; c=*p->p++; if(c=='"'||c=='\\'||c=='/'){} else if(c=='b')c=' '; else if(c=='f'||c=='n'||c=='r'||c=='t')c=' '; else if(c=='u') { if(p->end-p->p<4)return false; // preserve ASCII code points, replace others safely
                unsigned v=0;for(int i=0;i<4;i++){unsigned char h=*p->p++;if(!isxdigit(h))return false;v=(v<<4)|(isdigit(h)?h-'0':tolower(h)-'a'+10);} c=(v<128)?(unsigned char)v:'?';
            } else return false;
        }
        if(n>=MICA_HOOK_STRING_MAX)return false; if(out&&n+1<cap)out[n]=c; n++;
    }
    if(p->p==p->end)return false; p->p++; if(out){if(n>=cap)return false;out[n]=0;} return true;
}
static bool value(Parser *, unsigned);
static bool compound(Parser *p, bool object, unsigned depth) {
    if(depth>8)return false; p->depth=depth; p->p++ ; ws(p); unsigned count=0;
    unsigned char close=object?'}':']'; if(p->p<p->end&&*p->p==close){p->p++;return true;}
    for(;;){if(++count>512)return false; if(object){if(!string(p,NULL,0))return false;ws(p);if(p->p==p->end||*p->p++!=':')return false;ws(p);}
        if(!value(p,depth+1))return false;ws(p);if(p->p==p->end)return false;if(*p->p==close){p->p++;return true;}if(*p->p++!=',')return false;ws(p);}
}
static bool value(Parser *p,unsigned depth){ws(p);if(p->p==p->end||depth>8)return false;unsigned char c=*p->p;
    if(c=='{')return compound(p,true,depth);if(c=='[')return compound(p,false,depth);if(c=='"')return string(p,NULL,0);
    if(c=='-'||(c>='0'&&c<='9')){p->p++;while(p->p<p->end&&strchr("0123456789.eE+-",*p->p))p->p++;return true;}
    const char *l=c=='t'?"true":c=='f'?"false":c=='n'?"null":NULL;if(!l)return false;size_t n=strlen(l);if((size_t)(p->end-p->p)<n||memcmp(p->p,l,n))return false;p->p+=n;return true;
}
bool mica_hook_parse(const char *json,size_t length,MicaHookEvent *e){ if(!e)return false;memset(e,0,sizeof(*e));if(!json||!length||length>MICA_HOOK_LINE_MAX)return false;
    Parser p={(const unsigned char*)json,(const unsigned char*)json+length,0};ws(&p);if(p.p==p.end||*p.p++!='{')return false;ws(&p);unsigned fields=0;
    while(p.p<p.end&&*p.p!='}'){if(++fields>128)return false;char key[64];if(!string(&p,key,sizeof(key)))return false;ws(&p);if(p.p==p.end||*p.p++!=':')return false;ws(&p);
        char *dst=NULL;size_t cap=0;
#define FIELD(k,m) if(!strcmp(key,k)){dst=e->m;cap=sizeof(e->m);}
        FIELD("token",token) else FIELD("event",event) else FIELD("session_id",session_id) else FIELD("cwd",cwd) else FIELD("notification_type",notification_type) else FIELD("message",message) else FIELD("last_assistant_message",last_assistant_message) else FIELD("agent",agent) else FIELD("tool_name",tool_name)
#undef FIELD
        if(dst){if(!string(&p,dst,cap))return false;}else if(!value(&p,1))return false;ws(&p);if(p.p<p.end&&*p.p=='}')break;if(p.p==p.end||*p.p++!=',')return false;ws(&p);
    }
    if(p.p==p.end||*p.p++!='}')return false;ws(&p);if(p.p!=p.end||!utf8((const unsigned char*)json,length))return false;
    if(strlen(e->token)!=32)return false;for(size_t i=0;i<32;i++)if(!isxdigit((unsigned char)e->token[i]))return false;
    return e->event[0]&&(strcmp(e->agent,"claude")==0||strcmp(e->agent,"codex")==0);
}
