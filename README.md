# marketplace-plugins

Public catalogue and artifact host for Archous UISP plugins.

Modelled on [Ubiquiti-App/UCRM-plugins](https://github.com/Ubiquiti-App/UCRM-plugins), which does the
same thing for Ubiquiti's own plugins — a `plugins.json` index alongside committed archives.

## Layout

```
plugins.json                       the catalogue
plugins/<name>/<name>.zip          the archive for each plugin
```

Filenames are fixed per plugin, not versioned. The version lives in `plugins.json`, and git history
holds every previous byte sequence — so nothing accumulates in the working tree.

## plugins.json

```json
{
  "plugins": [
    {
      "name": "provisioner-v3",
      "displayName": "IP Provisioner",
      "version": "3.0.12",
      "zipUrl": "https://github.com/archous-networks/marketplace-plugins/raw/<sha>/plugins/provisioner-v3/provisioner-v3.zip",
      "sha256": "…",
      "unmsVersionCompliancy": { "min": "1.0.0-beta7", "max": null }
    }
  ]
}
```

**`zipUrl` pins a commit SHA, never a branch.** A published version therefore means one exact byte
sequence, permanently: re-tagging or force-pushing cannot change what `3.0.12` was. `sha256` is
checked by the consumer before anything is installed.

Fields mirror Ubiquiti's index so the shape is familiar, with `sha256` added.

## Publishing

```bash
bin/publish.sh release provisioner-v3 ../provisioner-v3/dist/provisioner-3.0.12.zip
```

Two commits, and the order is forced by the design: the archive must be committed before its SHA
exists, so the index is written second. `stage` and `index` are available separately for CI.

The publisher reads the plugin name and version from the archive's own `manifest.json` rather than
from arguments — that file is what UISP reads, so it is the only source that cannot disagree.

## Consumers

- **`marketplace`** plugin — reads this index to install and update plugins on a UISP instance.
- Anything else that wants a machine-readable list of Archous plugins.

Public on purpose. Plugin code ships to every instance and is readable there regardless; proprietary
logic belongs in Nautobot Jobs, not in a plugin. If something feels wrong to publish here, that is
the signal it is in the wrong place.
