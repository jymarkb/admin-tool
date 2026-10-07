#!/usr/bin/env python3
"""Read a pasted lightdark-flight log and say what it means.

Written after the second field run: the log said "HELD" 14 times for a flight
that never left the ground, because the check measured XZ only, and the -1000
arrived after a run of refused writes that no single line pointed at. This tool
re-reads such a log the strict way - both axes, and the refusals counted - so a
paste can be judged without trusting the build that produced it.

    python3 tools/read_flight_log.py logs/lightdark-flight-run2.log

It prints, per step: what was written, where the character actually was, how much
height was lost, and the verdict the current build would have given. Then it
replays the abort rules (3 in a row, and 3 of the last 4) over that run.
"""
import re
import sys

POS = r"\((-?[\d.]+), (-?[\d.]+), (-?[\d.]+)\)"
# v6-glide puts "jump 35.0 studs" between the step number and the s= range, so the
# prefix is not pinned to one wording
STEP = re.compile(r"step (\d{3}) \| .*?s=([\d.]+) -> ([\d.]+).*?asked " + POS)
# the check line changed shape in v5-smooth ("0.500s step | 10/10 write(s) stuck"),
# so the age is picked out of the prefix instead of being pinned to one wording
CHECK = re.compile(r"check (\d{3}) \| ([^|]*)\|[^|]*\|?\s*now " + POS +
                   r" \| ([\d.]+) (?:studs )?from (?:where it was written|the write)"
                   r".*?([\d.]+) from where it started\)?\s*\| (.+)$")
AGE = re.compile(r"([\d.]+)s")
SUMMARY = re.compile(r"^\S+\s+(route|asked|walked|position|net|steps|health|verdict|stopped)\s*\|")
TOLERANCE = 3.0          # TOLERANCE in the script
CONSECUTIVE = 3          # ABORT_AFTER_REVERTS
WINDOW, WINDOW_HITS = 4, 3   # refusals in the last N checks


def parse(lines):
    steps, checks = {}, []
    for line in lines:
        m = STEP.search(line)
        if m:
            steps[int(m.group(1))] = dict(
                s0=float(m.group(2)), s1=float(m.group(3)),
                pos=tuple(float(m.group(i)) for i in range(4, 7)))
            continue
        m = CHECK.search(line.strip())
        if m:
            am = AGE.search(m.group(2) or "")
            checks.append(dict(step=int(m.group(1)),
                               age=float(am.group(1)) if am else 0.0,
                               now=tuple(float(m.group(i)) for i in range(3, 6)),
                               dxz=float(m.group(6)), back=float(m.group(7)),
                               said=m.group(8).split(" - ")[0]))
    return steps, checks


def verdict(step, ch):
    """The axis split the current build uses, applied to the numbers in the log."""
    dxz, dy = ch["dxz"], ch["now"][1] - step["pos"][1]
    if dxz <= TOLERANCE and abs(dy) <= TOLERANCE:
        return "HELD"
    if dxz <= TOLERANCE:
        return "SAGGED"
    if ch["back"] <= TOLERANCE:
        return "REVERTED"
    return "MOVED"

REFUSALS = ("REVERTED", "MOVED")


def main(path):
    lines = open(path).read().splitlines()
    steps, checks = parse(lines)
    build = next((l.split("build ")[1].split(" |")[0]
                  for l in lines if "build " in l), "?")
    print(f"log       | {path}")
    print(f"build     | {build}")
    print(f"parsed    | {len(steps)} writes, {len(checks)} checks\n")

    print(f"{'step':>4} {'asked Y':>8} {'now Y':>7} {'XZ':>6} {'lost Y':>7}  "
          f"{'log said':<12} {'strict':<12}")
    for ch in checks:
        step = steps[ch["step"]]
        dy = ch["now"][1] - step["pos"][1]
        print(f"{ch['step']:>4} {step['pos'][1]:>8.1f} {ch['now'][1]:>7.1f} "
              f"{ch['dxz']:>6.1f} {-dy:>7.1f}  {ch['said']:<12} {verdict(step, ch):<12}")

    strict = [verdict(steps[c["step"]], c) for c in checks]
    sags = [c for c, v in zip(checks, strict) if v == "SAGGED"]
    worst = max((abs(c["now"][1] - steps[c["step"]]["pos"][1]) for c in sags), default=0)
    said_held = sum(1 for c in checks if c["said"] == "HELD")
    print(f"\nthe log called {said_held} of {len(strict)} checks HELD; "
          f"strictly {strict.count('HELD')} held, {len(sags)} sagged "
          f"(worst {worst:.1f} studs of height lost), "
          f"{strict.count('REVERTED')} reverted, {strict.count('MOVED')} moved elsewhere")

    grounded = [l for l in lines if "grounded=true" in l and "floor=Enum.Material.Plastic" in l]
    if grounded:
        print(f"the character was standing on the floor at {len(grounded)} logged moments")
    if sags:
        ch = sags[0]
        step = steps[ch["step"]]
        print(f"first sag     | step {ch['step']}: wrote Y {step['pos'][1]:.1f}, "
              f"{ch['age']:.2f}s later it was at Y {ch['now'][1]:.1f} "
              f"({abs(ch['now'][1] - step['pos'][1]):.1f} studs down), "
              f"XZ still {ch['dxz']:.1f} from the write")

    print("\nabort rules replayed over this run")
    run_streak, fired = 0, {}
    for i, v in enumerate(strict, 1):
        run_streak = run_streak + 1 if v in REFUSALS else 0
        window = sum(1 for w in strict[max(0, i - WINDOW):i] if w in REFUSALS)
        if run_streak >= CONSECUTIVE and "consecutive" not in fired:
            fired["consecutive"] = f"check {checks[i-1]['step']} ({CONSECUTIVE} refused in a row)"
        if window >= WINDOW_HITS and "window" not in fired:
            fired["window"] = (f"check {checks[i-1]['step']} ({window} of the last "
                               f"{WINDOW} refused)")
    print(f"  3 in a row   | {fired.get('consecutive', 'never fires - the refusals are not consecutive')}")
    print(f"  3 of last 4  | {fired.get('window', 'never fires')}")
    death = [l for l in lines if "DEATH" in l]
    print(f"  the death    | {death[0].split('] ', 1)[1] if death else 'no death logged'}")
    if "window" in fired and death:
        print("  => the 3-of-4 rule stops this run before the kill; the "
              "consecutive-only rule does not.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
