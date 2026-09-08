# CLAUDE.md

Ansible + kubeadm for a six-node bare-metal rack, with a USB installer that
gets nodes from blank metal to prepped. See `docs/deployment.md` and
`docs/installer.md` for the how; `docs/superpowers/specs/` for the why.

## Vocabulary

- **"image"** means the bootable installer **ISO** (`make iso`), never a
  container image or a disk image. It is written to a USB stick with `dd`.

## Git

- **Never `git add -A`.** Add the files you changed by name. The operator edits
  `inventory/` between turns to match the real rack, and a blanket add has
  swept those edits into unrelated commits three times. If an inventory change
  is yours to commit, commit it on its own with a message that says what
  changed in the rack.

## Verification boundary

State which stage each claim was verified on — real hardware, the VM rig at
`~/VMs/k8s-rack-rig`, or not at all. Green Ansible runs and green `helm
--wait` have both hidden broken clusters here.
