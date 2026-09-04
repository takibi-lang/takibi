# Read-only maintained-kernel state inspection over compiler-owned DWARF and
# --emit-debug-metadata output.
#
# Usage:
#   source scripts/kernel_debug_metadata.gdb
#   takibi-debug-metadata _build/kernel-debug-metadata.json
#   source scripts/kernel_state.gdb
#   takibi-kernel [PID]
python
import gdb
import re


def _tk_int(value):
    return int(value)


def _tk_eval(expression):
    try:
        return gdb.parse_and_eval(expression)
    except gdb.error as error:
        raise gdb.GdbError(f"cannot read '{expression}': {error}")


def _tk_metadata():
    metadata = globals().get("_takibi_debug_metadata")
    if metadata is None:
        raise gdb.GdbError(
            "load compiler metadata with takibi-debug-metadata first")
    return metadata


def _tk_constant(name):
    matches = [
        item["value"] for item in _tk_metadata()["constants"]
        if item["name"] == name
    ]
    if len(matches) != 1:
        raise gdb.GdbError(f"missing or ambiguous Takibi constant '{name}'")
    return matches[0]


def _tk_enum(type_name, value):
    matches = [
        item for item in _tk_metadata()["enums"]
        if item["name"] == type_name
    ]
    if len(matches) != 1:
        return f"{type_name}::<unknown-type>({value})"
    names = [
        case["name"] for case in matches[0]["cases"]
        if case["value"] == value
    ]
    if len(names) != 1:
        return f"{type_name}::<unknown>({value})"
    return f"{type_name}::{names[0]}({value})"


def _tk_named_constant(prefix, value):
    names = [
        item["name"] for item in _tk_metadata()["constants"]
        if item["name"].startswith(prefix) and item["value"] == value
    ]
    if len(names) != 1:
        return f"{prefix}<unknown>({value})"
    return f"{names[0]}({value})"


def _tk_array_item(array, index):
    element_pointer = array.address.cast(array.type.target().pointer())
    return (element_pointer + index).dereference()


def _tk_hex(value):
    return f"0x{value:016x}"


def _tk_thread_cpus():
    threads = list(gdb.selected_inferior().threads())
    selected = gdb.selected_thread()
    stopped_threads = []
    stopped_cpus = []
    try:
        for thread in threads:
            if not thread.is_stopped():
                continue
            stopped_threads.append(thread.num)
            thread.switch()
            cpu = None
            for register in ("$mpidr_el1", "$mpidr"):
                try:
                    cpu = _tk_int(gdb.parse_and_eval(register)) & 0xff
                    break
                except gdb.error:
                    continue
            if cpu is None and thread.name:
                match = re.search(
                    r"(?:CPU|cpu|core)[ #]*([0-9]+)", thread.name)
                if match:
                    cpu = int(match.group(1))
            if cpu is None:
                remote_id = thread.ptid[1]
                max_cpus = _tk_constant("KERNEL_MAX_CORES")
                if 1 <= remote_id <= max_cpus:
                    cpu = remote_id - 1
            if cpu is not None and cpu not in stopped_cpus:
                stopped_cpus.append(cpu)
    finally:
        if selected is not None:
            selected.switch()
    try:
        targets = gdb.execute("monitor targets", to_string=True)
    except gdb.error:
        targets = ""
    for match in re.finditer(
            r"\bbcm2712\.cpu([0-9]+)\b[^\n]*\bhalted\b", targets):
        cpu = int(match.group(1))
        if cpu not in stopped_cpus:
            stopped_cpus.append(cpu)
    return [thread.num for thread in threads], stopped_threads, stopped_cpus


def _tk_online_cpus():
    online = [0]
    secondary = _tk_constant("SECONDARY_CORE_ID")
    state = _tk_int(_tk_eval("kernel_secondary_boot_state"))
    if state == 0x100 + secondary:
        online.append(secondary)
    return online


def _tk_trace_layout():
    names = (
        "sequence", "cpu", "event", "pid", "generation", "peer_pid",
        "peer_generation", "state", "wait_reason", "root", "saved_sp",
        "aux",
    )
    positions = {
        name: _tk_constant(
            "KERNEL_PROCESS_TRACE_"
            + {
                "generation": "GENERATION",
                "peer_pid": "PEER_PID",
                "peer_generation": "PEER_GENERATION",
                "wait_reason": "WAIT_REASON",
                "saved_sp": "SAVED_SP",
            }.get(name, name.upper())
            + "_WORD")
        for name in names
    }
    stride = _tk_constant("KERNEL_PROCESS_TRACE_WORDS_PER_EVENT")
    if (len(set(positions.values())) != len(positions)
            or any(position < 0 or position >= stride
                   for position in positions.values())):
        raise gdb.GdbError("invalid compiler-owned process trace layout")
    return positions, stride


def _tk_trace_record(array, item, positions, stride):
    base = item * stride
    return {
        name: _tk_int(_tk_array_item(array, base + position))
        for name, position in positions.items()
    }


def _tk_read_events():
    cpu_count = _tk_constant("DIAGNOSTIC_TRACE_CPUS")
    capacity = _tk_constant("DIAGNOSTIC_TRACE_EVENTS")
    next_values = _tk_eval("diagnostic_trace_next")
    records = _tk_eval("diagnostic_trace_records")
    output = []
    for cpu in range(cpu_count):
        latest_before = _tk_int(_tk_array_item(next_values, cpu))
        first = max(1, latest_before - capacity + 1)
        copied = []
        damaged = 0
        for sequence in range(first, latest_before + 1):
            slot = cpu * capacity + ((sequence - 1) % capacity)
            record = _tk_array_item(records, slot)
            sequence_before = _tk_int(record["seq"])
            fields = {
                name: _tk_int(record[name])
                for name in ("cpu", "id", "a", "b", "c", "d")
            }
            sequence_after = _tk_int(record["seq"])
            if sequence_before != sequence or sequence_after != sequence:
                damaged += 1
            else:
                copied.append((sequence, fields))
        latest_after = _tk_int(_tk_array_item(next_values, cpu))
        if latest_after != latest_before:
            output.append(
                f"takibi-kernel: events cpu={cpu} status=replaced "
                f"before={latest_before} after={latest_after}")
            continue
        overwritten = max(0, latest_before - capacity)
        output.append(
            f"takibi-kernel: events cpu={cpu} count={len(copied)} "
            f"damaged={damaged} overwritten={overwritten} "
            "coherence=per-cpu")
        for sequence, fields in copied:
            event_name = _tk_named_constant("DiagnosticEvent", fields["id"])
            output.append(
                f"takibi-kernel: event seq={sequence} cpu={fields['cpu']} "
                f"id={_tk_hex(fields['id'])} name={event_name} "
                f"a={_tk_hex(fields['a'])} b={_tk_hex(fields['b'])} "
                f"c={_tk_hex(fields['c'])} d={_tk_hex(fields['d'])}")
    return output


def _tk_read_crash():
    snapshot = _tk_eval("crash_snapshot")
    valid_before = _tk_int(snapshot["valid"])
    if valid_before == 0:
        return ["takibi-kernel: crash status=unpublished"]
    if valid_before != 1:
        return [
            f"takibi-kernel: crash status=invalid valid={valid_before}"
        ]
    sequence_before = _tk_int(snapshot["sequence"])
    fields = {
        name: _tk_int(snapshot[name])
        for name in (
            "cpu", "vector_slot", "esr_el1", "far_el1", "elr_el1",
            "spsr_el1", "process_pid", "parent_pid", "process_state",
            "wait_reason", "root_slot", "root_l1", "root_asid",
            "trace_count",
        )
    }
    trace_limit = _tk_constant("KERNEL_CRASH_TRACE_EVENTS")
    if fields["trace_count"] > trace_limit:
        return [
            "takibi-kernel: crash status=invalid "
            f"trace_count={fields['trace_count']} limit={trace_limit}"
        ]
    trace_positions, trace_words = _tk_trace_layout()
    trace_records = []
    for item in range(fields["trace_count"]):
        trace_records.append(_tk_trace_record(
            snapshot["trace"], item, trace_positions, trace_words))
    valid_after = _tk_int(snapshot["valid"])
    sequence_after = _tk_int(snapshot["sequence"])
    if valid_after != 1 or sequence_after != sequence_before:
        return [
            "takibi-kernel: crash status=replaced "
            f"before={sequence_before} after={sequence_after} "
            f"valid={valid_after}"
        ]
    lines = [
        f"takibi-kernel: crash status=valid seq={sequence_before} "
        f"cpu={fields['cpu']} slot={fields['vector_slot']} "
        f"esr={_tk_hex(fields['esr_el1'])} "
        f"far={_tk_hex(fields['far_el1'])} "
        f"elr={_tk_hex(fields['elr_el1'])} "
        f"spsr={_tk_hex(fields['spsr_el1'])}",
        f"takibi-kernel: crash process pid={fields['process_pid']} "
        f"parent={fields['parent_pid']} "
        f"state={_tk_enum('ProcessSlotState', fields['process_state'])} "
        f"wait={_tk_enum('ProcessWaitReason', fields['wait_reason'])} "
        f"root={fields['root_slot']} l1={_tk_hex(fields['root_l1'])} "
        f"asid={fields['root_asid']} trace_count={fields['trace_count']}",
    ]
    for record in trace_records:
        lines.append(
            f"takibi-kernel: crash-trace seq={record['sequence']} "
            f"cpu={record['cpu']} "
            f"event={_tk_named_constant('ProcessTrace', record['event'])} "
            f"pid={record['pid']} gen={record['generation']} "
            f"peer={record['peer_pid']} "
            f"peer_gen={record['peer_generation']} "
            f"state={_tk_enum('ProcessSlotState', record['state'])} "
            f"wait={_tk_enum('ProcessWaitReason', record['wait_reason'])} "
            f"root={record['root']} sp={_tk_hex(record['saved_sp'])} "
            f"aux={_tk_hex(record['aux'])}")
    return lines


def _tk_collect_kernel(pid_argument):
    published_before = _tk_int(_tk_eval(
        "ddb_snapshot_published_sequence"))
    if published_before == 0:
        return [
            "takibi-kernel: ddb status=unpublished",
            *_tk_read_crash(),
        ]

    snapshot = _tk_eval("ddb_snapshot")
    sequence_before = _tk_int(snapshot["sequence"])
    if published_before != sequence_before:
        return [
            "takibi-kernel: ddb status=in-progress "
            f"sequence={sequence_before} published={published_before}",
            *_tk_read_crash(),
        ]

    process_limit = _tk_constant("DDB_PROCESS_RECORDS")
    trace_limit = _tk_constant("KERNEL_CRASH_TRACE_EVENTS")
    fd_limit = _tk_constant("CRASH_FD_SNAPSHOT_SLOTS")
    trace_positions, trace_words = _tk_trace_layout()
    process_count = _tk_int(snapshot["process_count"])
    trace_count = _tk_int(snapshot["trace_count"])
    truncated = _tk_int(snapshot["process_truncated"])
    root_live = _tk_int(snapshot["root_live"])
    if (process_count > process_limit or trace_count > trace_limit
            or truncated not in (0, 1) or root_live not in (0, 1)):
        return [
            "takibi-kernel: ddb status=invalid "
            f"process_count={process_count}/{process_limit} "
            f"trace_count={trace_count}/{trace_limit} "
            f"truncated={truncated} root_live={root_live}",
            *_tk_read_crash(),
        ]

    processes = []
    process_values = snapshot["processes"]
    for index in range(process_count):
        record = _tk_array_item(process_values, index)
        processes.append({
            name: _tk_int(record[name])
            for name in (
                "pid", "ppid", "state", "wait_reason", "saved_sp",
                "root_slot",
            )
        })

    fd_records = []
    for fd in range(fd_limit):
        kind = _tk_int(_tk_array_item(snapshot["fd_kind"], fd))
        if kind != 0:
            fd_records.append((
                fd, kind,
                _tk_int(_tk_array_item(snapshot["fd_object"], fd)),
            ))

    trace_records = []
    for item in range(trace_count):
        trace_records.append(_tk_trace_record(
            snapshot["trace"], item, trace_positions, trace_words))

    frame = _tk_eval(
        f"*(struct ExceptionFrame *){_tk_int(snapshot['frame_sp'])}")
    frame_fields = {
        name: _tk_int(frame[name])
        for name in ("elr_el1", "spsr_el1", "sp_el0", "tpidr_el0")
    }
    fields = {
        name: _tk_int(snapshot[name])
        for name in (
            "cpu", "entry_kind", "entry_source", "live_daif",
            "saved_daif", "esr_valid", "esr_el1", "far_el1",
            "scheduler_enabled", "reschedule_pending", "process_pid",
            "parent_pid", "process_state", "wait_reason", "root_slot",
            "root_l1", "root_asid",
        )
    }

    published_after = _tk_int(_tk_eval(
        "ddb_snapshot_published_sequence"))
    sequence_after = _tk_int(_tk_eval("ddb_snapshot.sequence"))
    if (published_after != published_before
            or sequence_after != sequence_before):
        return [
            "takibi-kernel: ddb status=replaced "
            f"before={sequence_before}/{published_before} "
            f"after={sequence_after}/{published_after}",
            *_tk_read_crash(),
        ]

    all_threads, stopped_threads, stopped_cpus = _tk_thread_cpus()
    online_cpus = _tk_online_cpus()
    coherent = set(online_cpus).issubset(stopped_cpus)
    selected_pid = (
        fields["process_pid"] if pid_argument is None else pid_argument
    )
    ready = sum(record["state"] == 1 for record in processes)
    running = sum(record["state"] == 2 for record in processes)
    blocked = sum(record["state"] == 3 for record in processes)
    exited = sum(record["state"] == 4 for record in processes)

    lines = [
        f"takibi-kernel: ddb status=valid seq={sequence_before}",
        "takibi-kernel: cpus "
        f"gdb_threads={','.join(map(str, all_threads)) or 'none'} "
        f"stopped={','.join(map(str, stopped_threads)) or 'none'} "
        f"stopped_cpus={','.join(map(str, stopped_cpus)) or 'unknown'} "
        f"online_cpus={','.join(map(str, online_cpus))} "
        f"coherent={'yes' if coherent else 'no'}",
        f"takibi-kernel: intr cpu={fields['cpu'] & 0xff} "
        f"entry={fields['entry_kind']} source={fields['entry_source']} "
        f"live_daif={_tk_hex(fields['live_daif'])} "
        f"saved_daif={_tk_hex(fields['saved_daif'])}",
        f"takibi-kernel: regs elr={_tk_hex(frame_fields['elr_el1'])} "
        f"spsr={_tk_hex(frame_fields['spsr_el1'])} "
        f"sp_el0={_tk_hex(frame_fields['sp_el0'])} "
        f"tpidr_el0={_tk_hex(frame_fields['tpidr_el0'])}",
        f"takibi-kernel: current pid={fields['process_pid']} "
        f"parent={fields['parent_pid']} "
        f"state={_tk_enum('ProcessSlotState', fields['process_state'])} "
        f"wait={_tk_enum('ProcessWaitReason', fields['wait_reason'])}",
        f"takibi-kernel: sched enabled={fields['scheduler_enabled']} "
        f"pending={fields['reschedule_pending']} "
        f"current={fields['process_pid']} ready={ready} running={running} "
        f"blocked={blocked} exited={exited} truncated={truncated}",
        f"takibi-kernel: vm pid={fields['process_pid']} "
        f"root={fields['root_slot']} live={root_live} "
        f"asid={fields['root_asid']} l1={_tk_hex(fields['root_l1'])}",
        f"takibi-kernel: fds pid={fields['process_pid']} "
        f"captured={fd_limit} remainder=not-captured",
    ]
    for fd, kind, object_slot in fd_records:
        lines.append(
            f"takibi-kernel: fd={fd} "
            f"kind={_tk_enum('UnifiedFdKind', kind)} "
            f"object={object_slot}")

    lines.append(
        f"takibi-kernel: processes count={process_count} "
        f"truncated={truncated}")
    selected = None
    for record in processes:
        lines.append(
            f"takibi-kernel: process pid={record['pid']} "
            f"ppid={record['ppid']} "
            f"state={_tk_enum('ProcessSlotState', record['state'])} "
            f"wait={_tk_enum('ProcessWaitReason', record['wait_reason'])} "
            f"root={record['root_slot']} "
            f"sp={_tk_hex(record['saved_sp'])}")
        if record["pid"] == selected_pid:
            selected = record
    if selected is None:
        suffix = " snapshot-truncated" if truncated else ""
        lines.append(
            f"takibi-kernel: selected pid={selected_pid} "
            f"status=not-captured{suffix}")
    else:
        lines.append(
            f"takibi-kernel: selected pid={selected_pid} status=captured "
            f"state={_tk_enum('ProcessSlotState', selected['state'])} "
            f"wait={_tk_enum('ProcessWaitReason', selected['wait_reason'])}")

    lines.append(f"takibi-kernel: trace count={trace_count}")
    for record in trace_records:
        lines.append(
            f"takibi-kernel: trace seq={record['sequence']} "
            f"cpu={record['cpu']} "
            f"event={_tk_named_constant('ProcessTrace', record['event'])} "
            f"pid={record['pid']} gen={record['generation']} "
            f"peer={record['peer_pid']} "
            f"peer_gen={record['peer_generation']} "
            f"state={_tk_enum('ProcessSlotState', record['state'])} "
            f"wait={_tk_enum('ProcessWaitReason', record['wait_reason'])} "
            f"root={record['root']} sp={_tk_hex(record['saved_sp'])} "
            f"aux={_tk_hex(record['aux'])}")
    lines.extend(_tk_read_events())
    lines.extend(_tk_read_crash())
    return lines


class TakibiKernel(gdb.Command):
    """Print a validated read-only kernel diagnostic snapshot."""

    def __init__(self):
        super().__init__("takibi-kernel", gdb.COMMAND_STATUS)

    def invoke(self, argument, from_tty):
        args = gdb.string_to_argv(argument)
        if len(args) > 1:
            raise gdb.GdbError("usage: takibi-kernel [PID]")
        pid = None
        if args:
            try:
                pid = int(args[0], 10)
            except ValueError:
                raise gdb.GdbError("usage: takibi-kernel [PID]")
            if pid <= 0:
                raise gdb.GdbError("usage: takibi-kernel [PID]")
        for line in _tk_collect_kernel(pid):
            gdb.write(line + "\n")


TakibiKernel()
end
