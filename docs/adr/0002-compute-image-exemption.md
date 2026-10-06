# ADR-0002: Time-limited Packer bootstrap exemptions

- **Status:** accepted for the supervised compute baseline demo
- **Date:** 2026-10-05

Packer must boot a marketplace image before the hardening role can turn it into
an approved gallery version. Its Azure builder also uses a temporary public IP
for SSH and package downloads. The normal approved-image and public-IP denies
therefore block the builder itself.

The free root owns a dedicated `rg-<project>-image-build` resource group, gated
by `enable_image_build=false`. During a bake it receives separate exemptions
from only `approved-vm-images` and `deny-public-ip`. Each has a fixed expiry no
more than four hours ahead. The normal SKU, host-encryption, tag and location
controls still apply. Packer restricts inbound SSH to the workstation's /32.
No workload or management VM receives these exemptions.

`make build-image` enables the timed build scope, installs the pinned role,
validates and runs Packer, then disables the build scope even when Packer fails.
Cleanup removes the resource group and both exemptions. `verify-teardown.sh`
fails if any build group or scoped exemption remains, including expired ones.
Expiry ends policy relief; it does not delete a running VM. The supervised
session still must run `make destroy` and teardown verification.

The second exemption is required in addition to the public-IP exemption proposed
in the original handoff. Without it, the stock source image cannot be booted.
Production should evaluate Azure VM Image Builder with a private build network,
controlled package egress and an independently scoped build subscription.

Gallery and image definitions add no hourly VM charges. Image versions use billed
storage until deleted. The timed bake uses one small VM, one managed disk and a
public IP; publish the current cost estimate before starting it.

The canonical role release is pinned in `ansible/requirements.yml`. During this
local-only session, `HARDENING_REPO` supplies the sibling Git repository at the
same tag, since publishing the tag is not authorized. The helper verifies the
local tag exists and installs it through Ansible Galaxy's Git source support.
