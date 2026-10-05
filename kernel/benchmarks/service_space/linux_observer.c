/* Disposable-guest observer: read one stopped-at-a-phase user process by PID. */
#include <linux/module.h>
#include <linux/pid.h>
#include <linux/sched.h>
#include <linux/sched/task.h>
#include <linux/fdtable.h>
#include <linux/file.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/mm.h>
static int target;
static int sample_pid(const char *value,const struct kernel_param *kp)
{
 struct task_struct *task;
 struct pid *pid;
 struct files_struct *files;
 struct fdtable *table;
 unsigned fds=0,regular=0,i,capacity;
 unsigned long hash=0,minrefs=~0UL,maxrefs=0;
 size_t body=0,dynamic=0,usable=0,process=0;
 int result=param_set_int(value,kp);
 if(result)return result;
 pid=find_get_pid(target);
 task=get_pid_task(pid,PIDTYPE_PID);put_pid(pid);
 if(!task)return -ESRCH;
 task_lock(task);
 files=task->files;
 if(!files){task_unlock(task);put_task_struct(task);return -ESRCH;}
 spin_lock(&files->file_lock);
 table=files_fdtable(files);
 body=sizeof(*files);process=sizeof(*task);capacity=table->max_fds;
 if(capacity>256 || is_vmalloc_addr(table->fd) || is_vmalloc_addr(table->open_fds)) {
  spin_unlock(&files->file_lock);task_unlock(task);put_task_struct(task);return -EINVAL;
 }
 if(table!=&files->fdtab) {
  dynamic=sizeof(*table)+capacity*sizeof(struct file *)+
   max_t(size_t,2*capacity/8+BITS_TO_LONGS(BITS_TO_LONGS(capacity))*sizeof(long),L1_CACHE_BYTES);
  usable=ksize(table)+ksize(table->fd)+ksize(table->open_fds);
 }
 for(i=0;i<table->max_fds;i++) {
  struct file *f=rcu_dereference_raw(table->fd[i]);
  if(!f)continue;
  fds++;
  if(i>=3&&S_ISREG(file_inode(f)->i_mode)) {
   unsigned long refs=atomic_long_read(&f->f_count);
   regular++;hash=hash*31+(unsigned long)f;
   if(refs<minrefs)minrefs=refs;
   if(refs>maxrefs)maxrefs=refs;
  }
 }
 spin_unlock(&files->file_lock);
 task_unlock(task);put_task_struct(task);
 pr_info("service space: pid=%d fds=%u regular=%u capacity=%u process=%zu fd_body=%zu fd_dynamic=%zu fd_dynamic_usable=%zu file_body=%zu hash=%lu minrefs=%lu maxrefs=%lu\n",target,fds,regular,capacity,process,body,dynamic,usable,sizeof(struct file),hash,regular?minrefs:0,maxrefs);
 return 0;
}
static const struct kernel_param_ops sample_ops={.set=sample_pid,.get=param_get_int};
module_param_cb(target,&sample_ops,&target,0600);
static int __init observer_init(void){return 0;}
static void __exit observer_exit(void){}
module_init(observer_init);module_exit(observer_exit);MODULE_LICENSE("GPL");
