# Ember branding

`ember-logo.svg` is the source. Everything else is generated from it:

```sh
rsvg-convert -w 256 -h 256 branding/ember-logo.svg -o installer/ember-logo.png
```

`installer/ember-logo.png` is what the image ships, wired to
`default-user-image` in `lightdm-gtk-greeter.conf` by `build/_image-inside.sh`.

⚠ Not under `assets/` — that directory is the RetroArch bundle and is
gitignored wholesale, which silently swallowed this file the first time.
