/* FreeBSD 15.0 observer for a single-threaded process parked by workload.c. */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/file.h>
#include <sys/filedesc.h>
#include <sys/vnode.h>
#include <sys/refcount.h>
#include <sys/malloc.h>
/* Private allocation shape from matching kern/kern_descrip.c (NDFILE=20). */
struct replay_freetable {struct fdescenttbl *table;SLIST_ENTRY(replay_freetable) next;};
struct replay_table0 {int nfiles;struct filedescent entries[20];};
struct replay_fd0 {struct filedesc body;SLIST_HEAD(,replay_freetable) old;struct replay_table0 initial;unsigned long map[1];};
static int sample(SYSCTL_HANDLER_ARGS)
{
 int pid=0,error;
 unsigned fds=0,regular=0,i,capacity,threads,retired=0;
 unsigned long hash=0,minrefs=~0UL,maxrefs=0;
 size_t dynamic=0,usable=0;
 struct proc *p;
 struct filedesc *fdp;
 struct replay_fd0 *base;
 struct replay_freetable *old;
 error=sysctl_handle_int(oidp,&pid,0,req);
 if(error||!req->newptr)return error;
 error=pget(pid,PGET_HOLD|PGET_NOTWEXIT,&p);
 if(error)return error;
 /* The harness keeps this process blocked until this request completes. */
 fdp=p->p_fd;
 if(!fdp){PRELE(p);return ESRCH;}
 base=(struct replay_fd0 *)fdp;
 FILEDESC_SLOCK(fdp);
 capacity=fdp->fd_nfiles;threads=p->p_numthreads;
 if(fdp->fd_files!=(struct fdescenttbl *)&base->initial)
  {dynamic+=offsetof(struct fdescenttbl,fdt_ofiles)+capacity*sizeof(struct filedescent)+sizeof(*old);usable+=malloc_usable_size(fdp->fd_files);}
 if(fdp->fd_map!=base->map){dynamic+=howmany(capacity,64)*sizeof(unsigned long);usable+=malloc_usable_size(fdp->fd_map);}
 SLIST_FOREACH(old,&base->old,next){retired++;usable+=malloc_usable_size(old->table);dynamic+=offsetof(struct fdescenttbl,fdt_ofiles)+old->table->fdt_nfiles*sizeof(struct filedescent)+sizeof(*old);}
 for(i=0;i<capacity;i++) {
  struct file *f=fdp->fd_ofiles[i].fde_file;
  if(!f)continue;
  fds++;
  if(i>=3&&f->f_type==DTYPE_VNODE&&f->f_vnode->v_type==VREG) {
   unsigned refs=refcount_load(&f->f_count);
   regular++;hash=hash*31+(unsigned long)f;
   if(refs<minrefs)minrefs=refs;
   if(refs>maxrefs)maxrefs=refs;
  }
 }
 FILEDESC_SUNLOCK(fdp);PRELE(p);
 printf("service space: pid=%d fds=%u regular=%u capacity=%u process=%zu fd_body=%zu fd_dynamic=%zu fd_dynamic_usable=%zu file_body=%zu hash=%lu minrefs=%lu maxrefs=%lu threads=%u retired=%u\n",pid,fds,regular,capacity,sizeof(struct proc)+sizeof(struct thread),sizeof(*base),dynamic,usable,sizeof(struct file),hash,regular?minrefs:0,maxrefs,threads,retired);
 return 0;
}
SYSCTL_PROC(_kern,OID_AUTO,service_replay,CTLTYPE_INT|CTLFLAG_RW|CTLFLAG_MPSAFE,0,0,sample,"I","Parked replay process PID");
static int event(module_t m,int type,void *arg){return type==MOD_LOAD||type==MOD_UNLOAD?0:EOPNOTSUPP;}
static moduledata_t mod={"service_observer",event,NULL};
DECLARE_MODULE(service_observer,mod,SI_SUB_DRIVERS,SI_ORDER_MIDDLE);
MODULE_VERSION(service_observer,1);
