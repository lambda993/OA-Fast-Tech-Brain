# Fast Tech brain

A computer player for **TA: Escalation** in
[Open Annihilation](https://github.com/open-annihilation/open-annihilation)
that races up the tech tiers. The brain package is the
[`fast-tech/`](fast-tech/) folder; what it does and how it plays is in
[its README](fast-tech/README.md).

The package sits in a folder of its own because a brain package may hold
only its own files, and because the same folder can be copied as is into
the project's brains repository.

## Pack and check

`oa-tool` comes with the game.

```sh
oa-tool brain pack fast-tech --out fast-tech.oabrain
oa-tool brain check fast-tech.oabrain --game-dir /path/to/totala \
  --mod "/path/to/Open Annihilation/Mods/escalation"
```

Install the `.oabrain` from the Library's **Brains** tab, or open it with the
game, then pick **Fast Tech** for a computer seat in an Escalation skirmish.

## Licence

GPL-3.0-only, see [LICENSE](LICENSE).
