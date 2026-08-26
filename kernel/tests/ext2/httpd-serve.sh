#!/bin/sh
# The browser demo as one command, so the ash prompt does not have to carry
# the port and the document root by hand. This file lives in /bin, so from
# the prompt it is just:
#
#     httpd-serve.sh &
#
# The trailing `&` is what keeps the prompt usable: BusyBox httpd -f stays in
# the foreground for the life of the daemon and never returns.
httpd -f -p 8080 -h /
echo "httpd-serve: daemon exited $?"
