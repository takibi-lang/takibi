# Read-only QEMU snapshot after workload.c emits a phase marker.
# Connect to its matching DWARF ELF first; this command does not call target code.
set pagination off
python
import gdb,struct,json
inf=gdb.selected_inferior()
assert gdb.lookup_type('struct ProcessRecord').sizeof==872
assert gdb.lookup_type('struct ProcessFdContext').sizeof==72
assert gdb.lookup_type('struct FdBlock').sizeof==400
assert gdb.lookup_type('struct FdEntry').sizeof==24
assert gdb.lookup_type('struct SharedObject').sizeof==80
def words(addr,n):return struct.unpack('<'+'Q'*n,bytes(inf.read_memory(addr,n*8)))
def address(name):return int(gdb.parse_and_eval('(unsigned long)&'+name))
pool=gdb.parse_and_eval("*(struct 'IntrusivePool$ProcessRecord' *)&scheduled_process_pool")
assert int(pool['lock']['word'])==0
result={'pools':{'process':{'live':int(pool['live_count']),'chunks':int(pool['chunk_count']),'capacity':int(pool['chunk_count'])*9,'bytes':int(pool['chunk_count'])*8192}},'actors':[]}
for name,sym in [('fd_context','fd_context_pool'),('fd_block','fd_block_pool'),('object','object_pool'),('image','process_image_pool'),('backing','address_space_backing_pool')]:
 lock,first=words(address(sym),2);assert lock==0
 chunks=capacity=live=size=0;seen=set()
 while first:
  assert first not in seen;seen.add(first)
  nxt,count,length=words(first,3)
  chunks+=1;capacity+=count;size+=length
  live+=sum((w&3)!=0 for w in words(first+24,count));first=nxt
 result['pools'][name]={'live':live,'chunks':chunks,'capacity':capacity,'bytes':size}
# ProcessRecord slots have an 8-byte generation word before the payload.
base=int(pool['chunk_head']);record=gdb.lookup_type('struct ProcessRecord');ctx=gdb.lookup_type('struct ProcessFdContext');entry=gdb.lookup_type('struct FdEntry');obj=gdb.lookup_type('struct SharedObject')
while base:
 header=words(base+8192-128,9)
 free=set();link=header[6]
 while link:
  assert base<=link<base+9*880 and (link-base)%880==0 and link not in free
  free.add(link);link=words(link+8,1)[0]
 assert 9-len(free)==header[7]
 for slot in range(9):
  if base+slot*880 in free:continue
  addr=base+slot*880+8
  proc=gdb.Value(addr).cast(record.pointer()).dereference()
  pid=int(proc['pid'])
  context_addr=int(proc['fd_context'])
  if not context_addr:continue
  context=gdb.Value(context_addr).cast(ctx.pointer()).dereference()
  fd=int(context['block_head']);blocks=0;visited=set();fds=regular=hashed=0;refs=[]
  while fd:
   assert fd not in visited;visited.add(fd);blocks+=1
   for i in range(16):
    item=gdb.Value(fd+i*24).cast(entry.pointer()).dereference()
    kind=int(item['kind'])
    if kind:fds+=1
    if kind==2:
     regular+=1;addr=int(item['object']);hashed=(hashed*31+addr)%2**64
     value=gdb.Value(addr).cast(obj.pointer()).dereference()
     refs.append(int(value['refs']['value']))
   fd=words(fd+384,1)[0]
  result['actors'].append({'pid':pid,'capacity':blocks*16,'fd_body':72,'fd_dynamic':blocks*400,'process':872,'context':context_addr,'fds':fds,'regular':regular,'file_body':80,'hash':hashed,'minrefs':min(refs) if refs else 0,'maxrefs':max(refs) if refs else 0})
 base=header[1]
print('service pools: '+json.dumps(result,sort_keys=True))
end
detach
quit
