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
curl -L -o /tmp/feed.sh https://github.com/airplanes-live/feed/releases/latest/download/install.sh
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

OK    Receiver input       connected at 127.0.0.1:30005
OK    Receiver activity    data flowing (256b in 2s sample)
OK    Feed service         running
OK    ADS-B uplink         connected
OK    Feeder ID            11111111-2222-3333-4444-555555555555
OK    Claim secret         present
OK    Website claim        registered, not yet claimed
OK    Server reception     currently receiving (last data seen 1m ago)
OK    MLAT service         running (name: public)
OK    Diagnostics push     enabled (default), last push 4m ago

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

If the website gave you a fresh claim secret (a same-IP claim, an account-side
"reset claim secret", or a support-issued reset), save it to the feeder with:

```
sudo apl-feed claim set
```

The command prompts for the secret and saves it locally. The feeder will use
the new value on its next contact with the website — no daemon restart needed,
because neither `airplanes-feed` nor `airplanes-mlat` consumes the claim
secret directly. Pass `--force` if a different secret is already saved on this
feeder.

If you need to set the **Feeder ID** itself (typically when restoring an
existing feeder onto fresh hardware and the website's "Reinstall feeder" page
shows you the previous UUID), use:

```
sudo apl-feed id set
```

This one *does* restart `airplanes-feed` and `airplanes-mlat`, because both
daemons consume the UUID at startup. Pass `--force` to overwrite a different
existing Feeder ID.

For the website-restore flow where you have **both** a UUID and a fresh
claim secret in hand:

```
sudo apl-feed restore --uuid <UUID-from-website>
```

Then paste the claim secret when prompted. The command writes both files
atomically (rolls back the UUID change if the secret write fails) and
restarts the daemons in one step. Add `--check` to validate without writing.

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
curl -L -o /tmp/update.sh https://github.com/airplanes-live/feed/releases/latest/download/update.sh
sudo bash /tmp/update.sh
```

## Legacy airplanes.live image users

If your Pi is running the legacy [airplanes.live image](https://github.com/airplanes-live/image-releases),
you can adopt the current feed scripts without reflashing — every feature of
the current feed scripts is available via the legacy web UI's update buttons.

1. Click **Update Webconfig**.
2. Click **Update Feeder**.

The first refreshes the on-disk update orchestration; the second runs it and
installs the current feed scripts onto the feeder. After that, the feeder
behaves as described elsewhere in this README.

For the redesigned base OS image and web UI, reflash the
[airplanes-live/image](https://github.com/airplanes-live/image) release —
there is no in-place upgrade for those.

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

A local web map is no longer bundled with this installer. If you want one, install
[wiedehopf/tar1090](https://github.com/wiedehopf/tar1090) directly — it reads the
JSON output of your local readsb decoder.

If you installed the bundled `/airplanes` map with an earlier release, uninstall
remains supported with:

```
sudo bash /usr/local/share/tar1090/uninstall.sh airplanes
```

## Change Settings

Run the installer again to change your feeder settings:

```
curl -L -o /tmp/feed.sh https://github.com/airplanes-live/feed/releases/latest/download/install.sh
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
