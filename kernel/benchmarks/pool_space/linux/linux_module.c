/* Dedicated SLUB cache replay. Never load this module on the host. */
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/numa.h>
#include <linux/cpu.h>
#include "slab-internal.h"
#include "slub-observation-types.h"
#include "replay-workload.h"
#if !defined(CONFIG_SLUB_DEBUG) || defined(CONFIG_SLUB_DEBUG_ON) || defined(CONFIG_SLUB_STATS) || defined(CONFIG_KASAN) || defined(CONFIG_MEM_ALLOC_PROFILING)
#error This observation module requires the documented non-debug SLUB configuration
#endif
static void sample(struct kmem_cache *s, unsigned id, unsigned count, const char *phase, unsigned live)
{
 unsigned long slabs=0, capacity=0, node_bytes=0;
 int nid;
 for_each_node_state(nid,N_NORMAL_MEMORY) {
  struct kmem_cache_node *n=s->node[nid];
  if (n) { slabs+=atomic_long_read(&n->nr_slabs); capacity+=atomic_long_read(&n->total_objects); node_bytes+=ksize(n); }
 }
 pr_info("pool replay: name=%s count=%u phase=%s object=%u pool=%zu chunks=%lu capacity=%lu live=%u bytes=%lu cpu=%zu nodes=%lu random=%zu stride=%u order=%u cpus=%u\n",
 names[id],count,phase,sizes[id],ksize(s),slabs,capacity,live,slabs*(PAGE_SIZE<< (s->oo.x >> 16)),
 sizeof(struct kmem_cache_cpu)*num_possible_cpus(),node_bytes,s->random_seq?ksize(s->random_seq):0,s->size,s->oo.x>>16,num_possible_cpus());
}
static long replay_work(void *unused)
{
 unsigned counts[]={32,128},c,id,i;
 void *objects[REPLAY_MAX] = {0};
 for(c=0;c<2;c++) for(id=0;id<9;id++) {
  unsigned count=counts[c];
  char name[64];
  struct kmem_cache *s;
  snprintf(name,sizeof(name),"takibi675_%s_%u",names[id],count);
  s=kmem_cache_create(name,sizes[id],8,SLAB_NO_MERGE,NULL);
  if(!s)return -ENOMEM;
  sample(s,id,count,"empty",0);
  for(i=0;i<count;i++) {objects[i]=kmem_cache_alloc(s,GFP_KERNEL);if(!objects[i])goto allocation_failed;}
  sample(s,id,count,"full",count);
  for(i=0;i<count;i+=2){kmem_cache_free(s,objects[i]);objects[i]=NULL;}
  sample(s,id,count,"half",count/2);
  for(i=0;i<count;i+=2){objects[i]=kmem_cache_alloc(s,GFP_KERNEL);if(!objects[i])goto allocation_failed;}
  sample(s,id,count,"refill",count);
  for(i=count;i>0;i--){kmem_cache_free(s,objects[i-1]);objects[i-1]=NULL;}
  sample(s,id,count,"free",0);
  kmem_cache_destroy(s);
  continue;
allocation_failed:
  for(i=0;i<count;i++)if(objects[i])kmem_cache_free(s,objects[i]);
  kmem_cache_destroy(s);
  return -ENOMEM;
 }
 pr_info("pool replay: done allocator=slub\n");
 return 0;
}
static int __init replay_init(void) { return work_on_cpu(0, replay_work, NULL); }
static void __exit replay_exit(void) {}
module_init(replay_init);module_exit(replay_exit);MODULE_LICENSE("GPL");
