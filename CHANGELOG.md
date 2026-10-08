# 0.2.0

## New

- Masque support
- Font controls for timer/stack text
- Hide swipe option
- Wrapping lines
  - This one is a bit janky, it won't work on "missing aura" displays nor when using "Show only the first N" in a group. This is just generally kinda rough with AuraContainers, if you're someone who is good at layout stuff and wants to get involved please do.

## Changed

I've reorganized settings a bit in a way that feels more natural for me. Probably this sort of change will continue to happen, hopefully the better polish compensates for any annoyance while settings move around.

## Removed

Loss of control displays are gone. Ultimately the handling was too different from AuraContainers in a way that I think was gonna cause long-term grief.

Probably I'll whip up my own thing for that later if a good one doesn't exist but if nothing else you can fall back to `HARMFUL|CROWD_CONTROL` displays.

I am hoping this kind of feature removal is uncommon-- I plan to focus pretty heavily on AuraContainers and not worry about other stuff. Dunno.
