#!/bin/sh
# The normal boot starts /bin/httpd directly through /etc/inittab. This
# wrapper remains useful for experiments after changing the port below; an
# unchanged second instance conflicts with the init-managed service on 8080.
httpd -f -p 8080 -h /
echo "httpd.sh: daemon exited $?"
