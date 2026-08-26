#!/bin/sh
# The browser demo as one command, so the ash prompt does not have to carry
# the port and the document root by hand. Start it with
#
#     /etc/httpd-serve.sh &
#
# The trailing `&` is what keeps the prompt usable: BusyBox httpd -f stays in
# the foreground for the life of the daemon and never returns.
#
# `exec` matters here. Without it this shell would stay parked in wait4 for
# as long as the demo runs, and a third process blocked on a fourth is not
# what the interactive shell scenario is for -- the daemon should be a direct
# child of the ash that started it, exactly as if its command line had been
# typed at the prompt.
exec /bin/httpd -f -p 8080 -h /
