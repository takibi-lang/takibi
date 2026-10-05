/* Dedicated UMA zones, serial CPU-0 allocation replay. */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/proc.h>
#include <sys/sched.h>
#include <sys/smp.h>
#include <sys/mutex.h>
#include <sys/smr.h>
#include <vm/vm.h>
#include <vm/vm_page.h>
#include <vm/uma.h>
#include <vm/uma_int.h>
#include "replay-workload.h"
#ifdef INVARIANTS
#error This observation module requires the documented GENERIC non-INVARIANTS kernel
#endif
/* Match the release bucket_zone_lookup rounding, including capped entries. */
static size_t bucket_size(uma_bucket_t b)
{
 unsigned i, entries;
 unsigned capacities[]={2,4,8,16,
  32-sizeof(*b)/sizeof(void *),64-sizeof(*b)/sizeof(void *),
  128-sizeof(*b)/sizeof(void *),256-sizeof(*b)/sizeof(void *)};
 if(!b)return 0;
 entries=capacities[7];
 for(i=0;i<8;i++)if(capacities[i]>=(unsigned)b->ub_entries){entries=capacities[i];break;}
 return roundup(sizeof(*b),sizeof(void *))+sizeof(void *)*entries;
}
static void sample(uma_zone_t z,unsigned id,unsigned count,const char *phase,unsigned live)
{
 uma_keg_t k=z->uz_keg;
 size_t bytes=uma_zone_memory(z),chunks=bytes/(PAGE_SIZE*k->uk_ppera);
 size_t zbytes=roundup(sizeof(*z)+sizeof(struct uma_cache)*(mp_maxid+1)+sizeof(struct uma_zone_domain)*vm_ndomains,UMA_SUPER_ALIGN);
 size_t kbytes=roundup(sizeof(*k)+sizeof(struct uma_domain)*vm_ndomains,UMA_SUPER_ALIGN);
 size_t buckets=0,hash=0,offpage=0;
 int cpu,domain;
 critical_enter();
 CPU_FOREACH(cpu) {
  struct uma_cache *cache=&z->uz_cpu[cpu];
  buckets+=bucket_size(cache->uc_allocbucket.ucb_bucket);
  buckets+=bucket_size(cache->uc_freebucket.ucb_bucket);
  buckets+=bucket_size(cache->uc_crossbucket.ucb_bucket);
 }
 critical_exit();
 for(domain=0;domain<vm_ndomains;domain++) {
  struct uma_zone_domain *d=ZDOM_GET(z,domain);
  uma_bucket_t b;
  ZDOM_LOCK(d);
  STAILQ_FOREACH(b,&d->uzd_buckets,ub_link)buckets+=bucket_size(b);
  buckets+=bucket_size(d->uzd_cross);
  ZDOM_UNLOCK(d);
 }
 if(k->uk_flags&UMA_ZFLAG_HASH)hash=k->uk_hash.uh_hashsize*sizeof(struct slabhashhead);
 if(k->uk_flags&UMA_ZFLAG_OFFPAGE) {
  unsigned n=k->uk_ipers>PAGE_SIZE/16?SLAB_MAX_SETSIZE:PAGE_SIZE/16;
  offpage=chunks*(sizeof(struct uma_hash_slab)+BITSET_SIZE(n));
 }
 printf("pool replay: name=%s count=%u phase=%s object=%u pool=%zu chunks=%zu capacity=%zu live=%u bytes=%zu keg=%zu buckets=%zu counters=%zu hash=%zu offpage=%zu stride=%u pages_per_chunk=%u cpus=%d flags=%u observed_live=%d\n",
 names[id],count,phase,sizes[id],zbytes,chunks,chunks*k->uk_ipers,live,bytes,
 kbytes,buckets,sizeof(uint64_t)*(mp_maxid+1)*4,hash,offpage,k->uk_rsize,k->uk_ppera,mp_ncpus,k->uk_flags,uma_zone_get_cur(z));
}
static int replay(module_t mod,int event,void *arg)
{
 void *objects[REPLAY_MAX] = {0};
 unsigned counts[]={32,128},ci,id,i;
 if(event==MOD_UNLOAD)return 0;
 if(event!=MOD_LOAD)return EOPNOTSUPP;
 thread_lock(curthread);sched_bind(curthread,0);thread_unlock(curthread);
 for(ci=0;ci<2;ci++)for(id=0;id<9;id++) {
  unsigned count=counts[ci];
  char name[64];
  uma_zone_t z;
  snprintf(name,sizeof(name),"takibi675_%s_%u",names[id],count);
  z=uma_zcreate(name,sizes[id],NULL,NULL,NULL,NULL,UMA_ALIGN_PTR,0);
  if(!z)goto zone_failed;
  sample(z,id,count,"empty",0);
  for(i=0;i<count;i++) {objects[i]=uma_zalloc(z,M_WAITOK);if(!objects[i])goto allocation_failed;}
  sample(z,id,count,"full",count);
  for(i=0;i<count;i+=2){uma_zfree(z,objects[i]);objects[i]=NULL;}
  sample(z,id,count,"half",count/2);
  for(i=0;i<count;i+=2) {objects[i]=uma_zalloc(z,M_WAITOK);if(!objects[i])goto allocation_failed;}
  sample(z,id,count,"refill",count);
  for(i=count;i>0;i--){uma_zfree(z,objects[i-1]);objects[i-1]=NULL;}
  sample(z,id,count,"free",0);
  uma_zdestroy(z);
  continue;
allocation_failed:
  for(i=0;i<count;i++)if(objects[i])uma_zfree(z,objects[i]);
  uma_zdestroy(z);
zone_failed:
  thread_lock(curthread);sched_unbind(curthread);thread_unlock(curthread);
  return ENOMEM;
 }
 thread_lock(curthread);sched_unbind(curthread);thread_unlock(curthread);
 printf("pool replay: done allocator=uma\n");
 return 0;
}
static moduledata_t replay_mod={"pool_space_replay",replay,NULL};
DECLARE_MODULE(pool_space_replay,replay_mod,SI_SUB_DRIVERS,SI_ORDER_MIDDLE);
MODULE_VERSION(pool_space_replay,1);
