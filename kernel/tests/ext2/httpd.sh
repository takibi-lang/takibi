#!/bin/sh
# The normal boot runs this command through /etc/inittab. This wrapper remains
# useful for experiments after changing the port below; an unchanged second
# instance correctly conflicts with the init-managed service on port 8080.
httpd -f -p 8080 -h /
echo "httpd.sh: daemon exited $?"
