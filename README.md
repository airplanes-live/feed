# airplanes.live feed client

Use this installer to feed your existing ADS-B receiver data to
[airplanes.live](https://airplanes.live/). It does not replace your decoder or
remove other feed clients.

If you do not already have a decoder installed, install one first, such as
[readsb](https://github.com/wiedehopf/adsb-scripts/wiki/Automatic-installation-for-readsb).

## Install

Find your antenna coordinates and elevation:

<https://www.freemaptools.com/elevation-finder.htm>

Then install the feed client:

```
curl -L -o /tmp/feed.sh https://raw.githubusercontent.com/airplanes-live/feed/main/install.sh
sudo bash /tmp/feed.sh
```

## Check Your Feed

Run:

```
sudo apl-feed status
```

Example:

```
airplanes.live feed check

OK    Feed service         running
OK    MLAT service         running
OK    Receiver input       connected at 127.0.0.1:30005
OK    Airplanes.live link  connected
OK    Feeder ID            11111111-2222-3333-4444-555555555555
OK    Claim secret         present
OK    Website claim        registered, not yet claimed (v1)
OK    Website feed         last data seen 1m ago

Result: feeding looks healthy
```

`OK` means that part is working. `CHECK` means the feeder may still work, but
something needs attention. `FIX` means that part is not working.

## Claim Your Feeder

Claiming connects this feeder to your airplanes.live account.

```
sudo apl-feed claim show
```

Then sign in at:

<https://airplanes.live/feeder/claim>

Enter the UUID and secret shown by the command.

If the website says the feeder is not registered yet, run:

```
sudo apl-feed claim register
```

## Back Up And Restore

Back up before replacing a Raspberry Pi, reinstalling the OS, or wiping an SD
card:

```
sudo apl-feed backup airplanes-feeder-backup.json
```

Keep the backup private. It contains the identity that lets the website
recognize this feeder.

Restore it on the new install:

```
sudo apl-feed restore airplanes-feeder-backup.json
```

Check a backup before restoring it:

```
sudo apl-feed restore --check airplanes-feeder-backup.json
```

If the new install already created a different feeder identity, use:

```
sudo apl-feed restore airplanes-feeder-backup.json --force
```

## Update

Update without reconfiguring:

```
curl -L -o /tmp/update.sh https://raw.githubusercontent.com/airplanes-live/feed/main/update.sh
sudo bash /tmp/update.sh
```

## Image Builder Integration

Image builds should use build mode so the rootfs is prepared without touching
live host services or baking per-device state into the image.

To run the full installer in a chroot, provide placeholder feeder config:

```
sudo AIRPLANES_BUILD_MODE=1 \
  AIRPLANES_MLAT_USER=airplanes_initial \
  AIRPLANES_LATITUDE=0 \
  AIRPLANES_LONGITUDE=0 \
  AIRPLANES_ALTITUDE=0 \
  bash install.sh --build-mode
```

Build mode still installs packages, writes files, enables systemd units, and
builds the feed components. It skips service starts/restarts, health checks,
claim registration, feeder ID generation, legacy process killing, and receiver
connectivity probing.

Image builders that create `/etc/airplanes/feed.env` themselves can call
`update.sh --build-mode` directly instead. New images should treat
`/etc/airplanes/feed.env` as canonical and generate `/etc/airplanes/feeder-id`
on first boot. Legacy images continue to be supported by the updater through
the `/boot/airplanes-config.txt`, `/boot/airplanes-env`, and
`/boot/airplanes-uuid` fallbacks.

## Local Map

Optional: install a local map interface for your data:

```
sudo bash /usr/local/share/airplanes/git/install-or-update-interface.sh
```

Open it at:

```
http://192.168.X.XX/airplanes
```

Replace `192.168.X.XX` with the address of your Raspberry Pi.

Remove the local map:

```
sudo bash /usr/local/share/tar1090/uninstall.sh airplanes
```

## Change Settings

Run the installer again to change your feeder settings:

```
curl -L -o /tmp/feed.sh https://raw.githubusercontent.com/airplanes-live/feed/main/install.sh
sudo bash /tmp/feed.sh
```

## Support

Start with:

```
sudo apl-feed status
```

If you ask for help on Discord, include the last 20 lines from:

```
sudo journalctl -u airplanes-feed --no-pager
sudo journalctl -u airplanes-mlat --no-pager
```

Restart the feed client:

```
sudo systemctl restart airplanes-feed
sudo systemctl restart airplanes-mlat
```

Remove the feed client:

```
sudo bash /usr/local/share/airplanes/uninstall.sh
```
