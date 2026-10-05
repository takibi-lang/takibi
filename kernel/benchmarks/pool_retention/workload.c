/* Real FD open/fork/wait/close churn, with UART outside measured batches. */
#define main service_baseline_main
#include "../service_space/workload.c"
#undef main
static unsigned long long now(void)
{
 long ts[2];
 if(call(113,1,(long)ts,0,0,0)!=0)_exit(97);
 return (unsigned long long)ts[0]*1000000000ULL+(unsigned long long)ts[1];
}
static void wide(unsigned long long n)
{
 char buf[24];unsigned used=0,i;
 do{buf[used++]=(char)('0'+n%10);n/=10;}while(n);
 for(i=used;i>0;i--)if(write(1,&buf[i-1],1)!=1)_exit(99);
}
int main(void)
{
 unsigned counts[]={1,32,128},ci,batch,round,i;
 int fds[128],child,status;
 puts_raw("retention workload: begin\n");
 for(ci=0;ci<3;ci++)for(batch=0;batch<7;batch++){
  unsigned count=counts[ci];
  unsigned long long start=now();
  for(round=0;round<16;round++){
   for(i=0;i<count;i++){
    fds[i]=open("/hello.txt",O_RDONLY);
    if(fds[i]!=(int)i+3)_exit(91);
   }
   child=fork();if(child<0)_exit(92);
   if(child==0)_exit(0);
   if(waitpid(child,&status,0)!=child||status!=0)_exit(93);
   for(i=count;i>0;i--)if(close(fds[i-1])!=0)_exit(94);
  }
  unsigned long long elapsed=now()-start;
  puts_raw("retention workload: count=");number(count);
  puts_raw(" batch=");number(batch);puts_raw(" rounds=16 ns=");wide(elapsed);puts_raw("\n");
 }
 puts_raw("retention workload: done\n");return 0;
}
