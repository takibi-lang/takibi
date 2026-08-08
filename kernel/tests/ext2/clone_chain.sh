# GitHub issue #246/#248: launches the closing-bar concurrency
# demonstration the same proven way kernel/tests/ext2/init.sh launches
# /user_payload -- a direct script-line exec, not `sh -c "..."` (that
# combination hung the kernel on real hardware for a freshly-built,
# never-before-loaded custom ELF; switching to this shape fixed it).
/clone_chain
echo "clone chain script done"
