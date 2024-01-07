# Installation

You will need to install some other packages:
`apt install libmojolicious-perl libjson-pp-perl libperl6-slurp-perl toot`.

Then as root, create a config file (readable only to root) as
`/etc/net-redundancy.json`.

Copy the executable (`net-redundancy.pl`) to `/usr/local/bin/`

Copy the systemd config (`net-redundancy.service`) to
`'/etc/systemd/system`

Execute:
```
systemctl enable net-redundancy
systemctl start net-redunadancy
```

View the logs with: `journalctl -u net-redundancy.service`


# Config file

In the `sampling` section, `delay` is the setting to ping every X number
of seconds.

`history` is the number of samples of pings to use.

`pings` is the number of pings per sample.

`delta` is the number required to switch to a lower priority network.

In the `holddown` section, `delay` is to to keep from switching back too
quickly.  `penalty` is the number of pings to subtract from the holddown
time.  `minimum` is to not allow subtracting below the minimum.

In the `device` section, `hostname`, `port`, and `key` deal with a VyOS
API endpoint.

The `Gateway` section defines networks, in priroity order.  `Address` is
the next hop IP.  `Targets` specifies the ping targets to use (which
should be configured to use the next hop listed in `address` to reach
their destination).  There is also a `toot` option that specifies what
to toot.

The config file goes in `/etc/net-redundancy

