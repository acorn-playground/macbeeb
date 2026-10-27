# Discs

The co-processors' system discs, put in drive 0 when the machine starts so
it boots, and the rest of the Master 512's discs. Like the ROMs, these aren't GPL: CP/M and DOS Plus are copyright
Digital Research (and their successors), their BIOSes and utilities Acorn
Computers. They're included, as BeebEm does, so the emulator works out of
the box.

| File | Disc | Source |
| --- | --- | --- |
| cpm-utilities.dsd | Acorn CP/M 2.2 (BIOS 1.20) and utilities, for the Z80 Second Processor | BeebEm (CPM_Utilities_Disc.dsd) |
| dosplus-boot.adl | Acorn Master 512 DOS Plus 1.2 boot disc (disc 1) | BeebEm (BBCMaster512-Disc1-DosPlusBoot.adl) |
| gem-applications.img | Master 512 disc 2: GEM and its applications | BeebEm (BBCMaster512-Disc2-GemApplications.img) |
| gem-data.img | Master 512 disc 3: GEM data | BeebEm (BBCMaster512-Disc3-GemData.img) |
| master512-miscellaneous.img | Master 512 disc 4: miscellaneous | BeebEm (BBCMaster512-Disc4-Miscellaneous.img) |

GEM is copyright Digital Research. The `.img` discs are in the Master 512's
800K DOS format.

## Econet

| File | What | Source |
| --- | --- | --- |
| econet-level1.ssd | Acorn Econet Level 1 file server (FS), printer server (PS) and utilities | BeebEm (DiscIms/econet_level_1_utils.ssd) |
| econet-level2.ssd | Acorn Econet Level 2 file server and disc manager | BeebEm (DiscIms/econet_level_2_utils.ssd) |

Copyright Acorn Computers; bundled as BeebEm bundles them, on the same basis
as the ROMs (see ROMs/README.md).

## Elite over Econet

| File | What | Source |
| --- | --- | --- |
| elite-over-econet-flicker-free.mbhd | Mark Moxon's Elite over Econet, flicker-free version, on an Acorn Level 3 file server's SCSI hard disc | elite.bbcelite.com (DiscIms for BeebEm: flicker-free/scsi0.dat and .dsc) |
| elite-over-econet.mbhd | The same, with the original ship drawing | elite.bbcelite.com (DiscIms for BeebEm: original/scsi0.dat and .dsc) |

The `.mbhd` files are BeebEm's `.dat` and `.dsc` packed by
`scripts/sparse-hard-disc.py`, leaving out the sectors that are all zeros.
Elite is copyright Ian Bell and David Braben (Acornsoft, 1984); Elite over
Econet is Mark Moxon's; these are the discs he publishes for playing it in an emulator. The
Level 3 file server is copyright Acorn Computers.
