/* Equal POSIX open/fork/wait/close operations; every phase waits for a newline. */
#ifdef TAKIBI_RAW_ABI
static long call(long nr,long a,long b,long c,long d,long e)
{
 register long x0 __asm__("x0")=a,x1 __asm__("x1")=b,x2 __asm__("x2")=c;
 register long x3 __asm__("x3")=d,x4 __asm__("x4")=e,x8 __asm__("x8")=nr;
 __asm__ volatile("svc #0":"+r"(x0):"r"(x1),"r"(x2),"r"(x3),"r"(x4),"r"(x8):"memory");
 return x0;
}
static long write(int fd,const void *p,unsigned n){return call(64,fd,(long)p,n,0,0);}
static long read(int fd,void *p,unsigned n){return call(63,fd,(long)p,n,0,0);}
static int open(const char *p,int flags){return call(56,-100,(long)p,flags,0,0);}
static int close(int fd){return call(57,fd,0,0,0,0);}
static int getpid(void){return call(172,0,0,0,0,0);}
static int fork(void){return call(220,17,0,0,0,0);}
static int waitpid(int pid,int *status,int flags){return call(260,pid,(long)status,flags,0,0);}
static void _exit(int status){call(93,status,0,0,0,0);for(;;){}}
#define O_RDONLY 0
#else
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#endif
static void puts_raw(const char *s){unsigned n=0;while(s[n])n++;if(write(1,s,n)!=(long)n)_exit(99);}
static void number(unsigned n){char buf[16];unsigned used=0,i;do{buf[used++]=(char)('0'+n%10);n/=10;}while(n);for(i=used;i>0;i--)if(write(1,&buf[i-1],1)!=1)_exit(99);}
static void phase(unsigned count,const char *name)
{
 char c=0;
 puts_raw("service replay: count=");number(count);puts_raw(" phase=");puts_raw(name);
 puts_raw(" pid=");number((unsigned)getpid());puts_raw("\n");
 do {if(read(0,&c,1)!=1)_exit(98);}while(c!='\n');
}
int main(void)
{
 unsigned counts[]={32,128},ci,i;
 int fds[128],child,status;
 for(ci=0;ci<2;ci++) {
  unsigned count=counts[ci];
  phase(count,"baseline");
  for(i=0;i<count;i++){fds[i]=open("/hello.txt",O_RDONLY);if(fds[i]!=(int)i+3){puts_raw("service replay: FAILED open/FD sequence\n");return 1;}}
  phase(count,"opened");
  child=fork();
  if(child<0){puts_raw("service replay: FAILED fork\n");return 2;}
  if(child==0){phase(count,"inherited");_exit(0);}
  if(waitpid(child,&status,0)!=child||status!=0){puts_raw("service replay: FAILED wait\n");return 3;}
  phase(count,"reaped");
  for(i=count;i>0;i--)if(close(fds[i-1])!=0){puts_raw("service replay: FAILED close\n");return 4;}
  phase(count,"closed");
 }
 puts_raw("service replay: done\n");return 0;
}
#ifdef TAKIBI_RAW_ABI
__asm__(".global _start\n_start:\nbl main\nmov x8, #93\nsvc #0\n");
#endif
