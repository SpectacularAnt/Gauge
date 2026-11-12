# Gauge

A menu bar readout for your Mac's hardware. Pick which numbers sit in the menu
bar, click them for the full picture.

![what it looks like](docs/menubar.png)

## Running it

Gauge is installed in your **Applications** folder. The source lives here; the
app itself does not, so that nothing iCloud might move or evict ends up being
the copy macOS launches.

1. Open Gauge from Applications or Launchpad.
2. Look at the right side of your menu bar. You should see three readings:
   processor usage, chip temperature, and memory used.
3. Click them. A panel opens with four tabs.
4. Go to the **Settings** tab to choose what appears in the menu bar.

There is no Dock icon and no window — the menu bar item *is* the app. To quit,
either use the button at the bottom of Settings, or right-click the menu bar
item and choose Quit.

To rebuild after changing the code, run `./build.sh`. It compiles, replaces
`/Applications/Gauge.app`, and relaunches — quitting the running copy first,
since a running app cannot be replaced in place. Your settings survive, because
they are keyed to the app's identifier rather than its location.

## Starting it with your Mac

In **Settings > Starting up**, switch on *Open Gauge at login*. Gauge then
appears in System Settings > General > Login Items, where you can also turn it
off again.

macOS remembers a login item **by the app's location**, which is the reason
Gauge lives in `/Applications` rather than next to its source. A copy inside
Documents syncs to iCloud, and if iCloud were to move or evict it, macOS would
be pointing at a file that is not there — Gauge would quietly stop opening at
login, with no error to tell you why. From `/Applications` nothing moves it.

The app still carries that warning and shows it if it ever finds itself running
from a synced folder again. If you do move the app, switch the setting off and
on so macOS learns the new location.

There is no saved setting behind that switch. It reads the system's own answer
every time the panel opens, so if you turn Gauge off in System Settings the
switch here agrees with you rather than insisting it is still on.

## What it can show you

Fourteen readings, each one switched on or off independently in Settings:

| Group | Readings |
| --- | --- |
| Processor | CPU usage, chip temperature, GPU usage, load average |
| Memory | memory used, memory pressure, swap used |
| Storage | disk used, disk activity, SSD temperature |
| Network | network activity |
| Power | battery charge, power draw, battery temperature |

The panel always shows everything, whatever you have switched on in the bar:

- **Overview** — the whole machine, described below.
- **Sensors** — every temperature sensor the Mac will admit to, by name.
- **Apps** — what each program costs, described below.
- **Settings** — the switches, how often to refresh, and °C or °F.

## The Overview

The problem with showing everything is that everything is a lot. The Overview
answers it in three layers, so the detail is there without being in the way.

**At the top, four rings and three facts.** Processor, memory, graphics and chip
temperature, each as a filled arc, plus thermal state, power and uptime. This
part never scrolls away behind a fold and never collapses — a glance at the
rings is meant to be enough to know whether anything needs your attention.

**Below that, eight sections you can fold.** Processor, Memory, Graphics,
Temperature, Power, Storage, Network and System. Each remembers whether you left
it open, so the panel ends up shaped the way you use it rather than the way it
shipped. Storage, Network and System start folded; the rest start open. There
are *Expand all* and *Collapse all* links if you want everything at once or
nothing at all.

**A folded section is not a hidden one.** Its header keeps the headline number
and a small trend line, so closing a section you are not watching closely still
leaves you able to see it change. That is the whole trick to fitting this much
into one panel.

### Reading the graphs

Each section draws its recent history — four minutes by default. Settings has
a **Trend length** slider from 1 to 30 minutes. Widening it keeps the history
you already have and lets it grow into the new space; narrowing it drops the
oldest readings. The window is measured in minutes rather than readings, so
changing the refresh rate does not change how far back the lines reach.

The shapes are meant to be readable without reading the numbers, so two rules
keep them honest:

- **Percentages and temperature are drawn on a fixed scale.** Processor, memory
  and graphics run 0–100%, and temperature runs 0–100°C. A flat line really
  means nothing is happening. If these scaled themselves to whatever the last
  few minutes contained, half a degree of ordinary drift would draw a mountain
  range and you would learn to ignore it.
- **Transfer rates scale to what they contain,** because a download can be a
  thousand times faster than the background chatter either side of it and a
  fixed scale would flatten everything interesting. The current figures are
  printed beside the chart, so the shape tells you the pattern and the numbers
  tell you the size.

Disk and network each draw two directions against **one shared scale**, read
above the line and written below, so the two halves can be compared directly
rather than each being stretched to fill its own half.

### Finding out when something happened

Run the pointer along any chart in the Overview. A thin vertical line follows
it, a dot marks the reading underneath, and a small box above the chart says
what the value was and when:

    28%
    7:01:26 AM · 25s ago

The line snaps to the nearest actual reading, so you aim at a moment rather
than having to land on a two-point line. The box sits above the chart — over
the card's heading, not over the data you are trying to look at — and to
whichever side of the pointer has room, so it never runs off the edge.

On the disk and network charts the box gives **both** directions at that
moment, each marked with a short stroke of its line's colour, so there is no
hunting for the second value:

    ━ 1.0 KB/s  Down
    ━ 1.0 KB/s  Up
    7:04:34 AM · 24s ago

The times are the real moments each reading was taken, recorded alongside it,
not worked out from the refresh rate — so they stay right even if the refresh
rate changed partway through the window, or a reading arrived late. Leave the
pointer still and the box keeps describing whatever is under it as new readings
scroll in.

The small trend lines in a folded section's header are not scrubbable; they are
too small to aim at. Open the section to scrub it.

**Why download and upload often read the same at idle.** The Mac's network
counters move in steps of exactly 1,024 bytes. With only background chatter
going on, both directions often land on the same step in a given interval, so
"1.0 KB/s Down, 1.0 KB/s Up" is a true reading, not a fault. Real traffic is
far larger than one step and the two separate at once.

### Looking back further than the last few minutes

The row of buttons above the sections picks how far back every chart on the
tab reaches:

| | What it draws |
| --- | --- |
| **Live** | the trend length from Settings, every reading, held in memory |
| **1h, 6h, 24h, 7d** | one point a minute, read back off the disk |

**Live** is the original behaviour and is unchanged: full detail, up to half an
hour, gone when Gauge quits. The other four come from a file Gauge keeps, so
they survive quitting, restarting and shutting down. That is the difference
between "what is happening" and "what happened" — if the Mac was slow at four
o'clock, the 6h view still has four o'clock in it at bedtime.

Scrubbing works the same way on every range, so you can run the pointer along
a week and read off the clock time of whatever you land on.

**What gets written down.** Once a minute Gauge averages that minute's
readings — processor, memory, graphics, temperature, network both ways, disk
both ways and power — and appends one line to:

    ~/Library/Application Support/Gauge/history.csv

It is plain text, one line per minute, seconds-since-1970 first and then the
nine series, so `cat` or a spreadsheet can read it without Gauge's help.
Anything older than **30 days** is dropped. That is about 43,000 lines and a
couple of megabytes, which is small enough that older readings never need
thinning out — every line in the file means exactly the same thing.

**Two things the long views cannot do.** The first is show you a brief spike:
a minute is already an average, and a week squeezed into a 380-point-wide chart
groups about half an hour into each point, so a ten-minute burst of full load
reads as a bump rather than a cliff. Use **Live** when the exact shape matters.
The second is show you time Gauge was not watching. Gauge only records while it
is running, so quitting it, or closing the lid, leaves a hole. Rather than draw
a smooth line across an afternoon nobody watched, **the chart breaks**: the
line stops and starts again on the other side of the gap.

The note beside the buttons says what you are actually getting — `saved to
disk` when the range is full, or `only 3h saved so far` when Gauge has not been
watching that long yet. A fresh install has nothing in the file, so the long
ranges start out empty and fill in as they go.

Colour is doing two different jobs, kept apart on purpose. The rings and the
load bars use **green through red to mean "how close to the limit"**. The charts
use a **fixed set of series colours for identity** — the same blue means the
first series everywhere, so colour never changes meaning between one card and
the next. Nothing relies on colour alone: every segment and every series is
named and valued in text beside it.

### Putting the sections in your order

**Rearrange sections**, at the very bottom of the Overview, swaps the sections
for a short list with up and down arrows beside each name. Move them where you
want them and press **Done**; **Reset order** goes back to the usual one. The
order is saved, and a section a later version of Gauge adds goes on the end.
Power keeps its place on a Mac without a battery but is simply not shown.

### Inspecting a section

Open any section of the Overview and the last line is **Inspect** followed by
the section's name. It opens a page with everything Gauge can find out about
that part of the Mac: a taller chart, the average, highest and lowest over
whatever range is picked (with when each happened), and then every fact in
titled blocks. **‹ Overview** at the top goes back, to the section you came
from. Values that are worth worrying about turn orange or red and carry an
icon. Anything can be selected and copied — serial numbers, addresses, paths.

| Page | What is on it beyond the Overview |
| --- | --- |
| Processor | every core on its own, idle time, all three load averages, programs running, cache sizes per cluster |
| Memory | what is completely unused, and counts since startup: swap-ins and -outs, page-ins and -outs, compressions, faults, purges |
| Graphics | how busy drawing and geometry are separately, how much memory the GPU may use, Metal family, ray tracing, each display in points and pixels |
| Temperature | every sensor, hottest first, and the SSD's own temperature report |
| Power | the battery in milliamp-hours (as designed, full now, holding now), cycles out of its rating, condition, measuring chip, and the power adapter |
| Storage | each drive's full health report (below), and each volume's format, mount point and FileVault state |
| Network | router, DNS, this Mac's network name, and per connection: addresses, link speed, packet size, packets and errors; unused ports in one line |
| System | serial number, kernel, computer name, signed-in account, and where Gauge keeps its history |

### Choosing what a section lists

The lines under each Overview section's chart are yours to pick, from anything
on that section's Inspect page. Press **Edit** at the top right of the page and
every fact on it gets a tick box; ticked ones show in the Overview. **Done**
puts the page back to reading, and **Reset**, beside the note that appears
while editing, puts that one section back as it came. The charts, the core
bars and the memory bar always stay, since they are what the section is.

Most sections' usual lines are facts on the page too ("Your programs", "Load
average", a drive's "Health"). Ticking one of those switches the Overview's own
version of it, which keeps the bars and combined values the Overview has
always drawn (`OverviewDetail` says which fact stands for which line). Any
other fact, such as a single core, the week's highest reading or the serial
number, is shown after them as the page shows it, under a small heading naming
its block, since "Health" or "Status" alone would not say whose.

A line with nothing to say at the moment, such as time remaining while the
battery is full on mains power, simply does not appear. Choices are saved by
section, block and label, so they survive restarts; macOS gives a few
temperature sensors the same name, so those are numbered to keep them apart.

Some page facts take a system call or a quick run of `netstat` to gather, and
SwiftUI redraws far more often than readings arrive, for example on every
mouse move over a chart. So the Overview gathers a section's facts once per
reading, and only while that section is open and something from it is picked
(`FactCache` in `DetailPanel.swift`).

### Drive health

Every NVMe SSD keeps a health log that it updates itself: how much of its
rated endurance it has used, how much spare flash it has left to replace worn
cells, how much has been written to it over its life, how long it has been
powered on, and any faults. iStat Menus and DriveDx read it; Disk Utility only
ever boils it down to "Verified", which is how a drive can be nearly worn out
without anyone being told. Gauge reads it directly, with no password and
nothing installed, through a plug-in macOS ships for this
(`NVMeSMARTLib.plugin`, the same route `smartctl` uses). It checks every ten
minutes, which is far more often than wear changes.

**Health** is what is left of the rated endurance: 100% new, 0% at the end of
its rating. Drives often outlive the rating, but under about half is a good
time to plan. The Storage section shows it as a bar; the Inspect page has the
whole report. If the drive raises an alarm of its own — spare space below its
safe level, too hot, errors, or switching itself to read-only — it is listed in
red, whatever the percentage says.

Drive sizes and lifetime totals use powers of a thousand, the way drive makers
state them, so a drive sold as 1 TB reads as 1 TB. Everywhere else Gauge counts
in powers of 1,024, as memory always has.

## The Devices tab

Everything paired with or plugged into this Mac: headphones, mice and
keyboards, phones and watches, anything on a USB cable. Connected devices come
first, then the ones that are paired but away. Each row shows what the device
is, who made it, and its batteries where they are known, as *L 78%  R 77%
C 97%* for earbuds. Click one for its page: batteries as bars, connection,
signal strength, firmware, serial numbers and the rest.

How much each device shows is up to macOS, not Gauge:

| Device | What macOS lets apps see |
| --- | --- |
| AirPods and Beats | each earbud's and the case's battery (as last reported, when not connected), firmware, serial numbers |
| Apple keyboards, mice, trackpads | battery while connected, firmware |
| Other makers' headphones and mice | name, maker, firmware, Bluetooth profiles, and the battery whenever macOS shows one in Control Center |
| iPhone, iPad | **name and signal strength only**; battery and storage stay on the device |
| Apple Watch | **name and signal strength only**; it pairs with the iPhone, not the Mac |
| USB devices | name, maker, speed, serial number |

Any device with a battery has a **Show battery in the menu bar** switch on
its page. Chosen devices sit at the end of the menu bar with their glyph (or a
short name, in the Labels style) and their level: the only battery, or the
lower earbud. Under the switch, **Always** shows it whenever it is connected,
and **When low** only once it drops below a level you set (5–95%, 20% to
begin with). A device is only ever there while it is connected to this Mac:
AirPods sitting in their case nearby still report their battery, but they drop
out of the menu bar until you connect them. With any chosen, Gauge looks at devices once a minute even with the
panel shut; otherwise only while the Devices tab is open.

A phone or watch that is not connected but shows a signal is in range; the
row says *nearby*. Signal is in dBm, a negative number where nearer zero means
closer.

Each device is drawn as a ring like the ones at the top of the Overview: the
ring is its battery (the lower earbud, for AirPods), its colour sliding from
green when full through yellow at half to red when empty. The same colour is
used for the battery bars on a device's page and for its glyph in the menu
bar (or its number, in the Labels and Values styles). Anything not connected is grey; something on a cable shows a
cable; with no battery known the ring is left as an empty track. AirPods use
Apple's own AirPods glyphs.

Batteries come from macOS's list of power sources, the same one `pmset -g
accps` prints and Control Center reads: the Mac's own battery plus every
accessory's. That is where non-Apple headphones and mice keep theirs; the
Bluetooth report leaves them out, which is why the first version showed empty
rings for a Sony headset at 29% and a Logitech mouse at 70%. The function that
reads the accessory half, `IOPSCopyPowerSourcesByType`, is the one `pmset`
uses but is missing from Apple's public headers, so Gauge looks it up by name
and, if a later macOS drops it, falls back to the Bluetooth report's
batteries instead of failing.

Bluetooth devices come from `system_profiler SPBluetoothDataType`, the report
System Information shows, run in the background every ten seconds while the
tab is open and the panel is showing, and never otherwise. USB devices come
from the I/O registry. Gauge does not use Apple's private ways of reading an
iPhone's or Watch's battery: they are undocumented and break with macOS
updates. The first time Gauge reads Bluetooth, macOS may ask whether Gauge may
use it.

## The Apps tab

Every program doing anything at all, or holding at least 100 MB of memory, with
four columns: **CPU**, **GPU**, **Power** and **RAM**. Click a column heading to
order the list by it; click the same heading again to turn the order around. The
choice is remembered.

- **CPU** is percent of *one* core, so a program using four cores flat out reads
  400. That is how macOS counts it everywhere, and it means a single runaway
  program stands out at about 100 regardless of how many cores the Mac has.
- **GPU** is that program's share of the graphics chip.
- **Power** is macOS's own *energy impact* figure — the same number Activity
  Monitor shows. It is mostly CPU, plus the cost of waking the processor up,
  plus graphics and disk. For a program that is purely computing, it reads
  almost exactly the same as its CPU figure.
- **RAM** is the memory the program is holding — its *memory footprint*, the
  same figure Activity Monitor's Memory column shows. Programs that split
  themselves into helper processes, as Chrome does with each tab, appear as
  several rows rather than one total.

A dash means nothing measurable. Thousands of background services sit idle at
any moment, holding a few megabytes each; they are left out so the list is about
what is actually working or actually big. A program that is idle but sitting on
a lot of memory stays in, because that is exactly what the RAM column is for.

### Opening a row

Click any program in the list to open it. Underneath you get:

- **Recent CPU** as a small chart of that one program's last couple of minutes,
  which separates "it has been pegged all along" from "it just started".
- **What it is**, for the many programs whose names say nothing on their own:
  *Part of Google Chrome* for one of Chrome's helpers, *Started by Terminal*
  for a script, *Part of macOS* for the system's own background work. Gauge
  looks for the app whose bundle the program lives inside, then for an app
  that started it, then at whether it lives in one of macOS's own folders.
- **Process ID**, the number macOS knows it by.
- **Running since**, the clock time it started and how long ago that was.
- **Where**, the full path to the executable it is running.

and three things you can do about it:

- **Show** brings the program forward the way clicking it in the Dock does,
  so you can see what it is. For a helper or a script it brings forward the
  app it belongs to, and says so: *Show Google Chrome*. It only ever shows an
  app that is already open and never launches anything. Plenty of programs
  have nothing to show — macOS's background services, menu bar apps, an app's
  helper while the app itself is shut — and for those a line under the buttons
  says why instead.
- **Reveal in Finder** opens the enclosing `.app` where there is one, rather
  than landing three folders deep inside the bundle.
- **Quit** asks the program to quit the ordinary way — the same request the
  Dock makes, so an app with unsaved work still gets to ask you about it.
  Programs with no interface get a plain `SIGTERM` instead, which is what
  `kill` sends by default. Either way the button asks you to confirm first,
  because it sits next to buttons that do nothing irreversible.

**Quit is only offered for your own programs.** Anything belonging to macOS or
another account says *Belongs to macOS* instead. This is not just politeness:
the window server runs as its own user and ending it logs you out. Gauge works
out the owner from the kernel's process table and compares it with yours.

### The warning sign

Everything to do with busy programs lives in one card, **Settings > App
alerts**. Its top switch, *Flag programs that use a lot*, is on to begin with.
Turned off, nothing in the Apps tab is flagged, the menu bar count and the
notifications below stop, and the limits disappear from Settings, since they
would do nothing. Gauge remembers what you had chosen underneath, so turning it
back on puts everything as it was.

With it on, a ⚠️ appears next to any program over one of these limits, each of
which can be moved in the same card:

| | Default | Range |
| --- | --- | --- |
| CPU | 80% | 20% – 400% |
| GPU | 50% | 10% – 100% |
| Energy impact | 80 | 20 – 400 |
| RAM | 4 GB | 512 MB – 16 GB |

The offending figures turn orange, and a **Using a lot** card at the top of the
tab lists each flagged program with the reason in words.

The thresholds are deliberately high. A warning that fires all day is one you
learn to ignore, so these are meant to catch "this is why the Mac is hot", not
"this program is awake". Two of them are set where they are for a reason:

- **CPU is 80%, not 100%.** A single-threaded program stuck in a loop reads
  about 99.8% and would never cross 100. That is exactly the case most worth
  catching, so the line sits under it.
- **RAM is 4 GB.** That is an eighth of this Mac's 32 GB, and well clear of
  what the biggest programs here hold while idle — Final Cut Pro sits at about
  1.5 GB — so it catches a program that has grown out of hand rather than one
  that is simply large.

CPU and energy impact go up to 400 because both count per core: a program
using four cores flat out reads 400, and you may only care about that. The
RAM limit moves in steps rather than smoothly — 512 MB, then 1, 2, 3, 4, 6, 8,
12 and 16 GB — because the useful settings span a wide range, and a smooth
slider would cram the small ones into its first few pixels. The steps use the
same units as the Apps tab, so a 4 GB limit trips at exactly what the Apps tab
calls 4 GB.

A change takes effect at the next reading, and **Reset limits** puts all four
back.

### Counting warnings in the menu bar

**Show the count in the menu bar**, in the App alerts card, is off by
default. Turned on, it shows ⚠
and the number of programs currently over a threshold. At zero it disappears,
so seeing it appear is the alert; the readouts beside it shift along when it
does.

It is off by default because it costs something the rest of the menu bar does
not. Counting warnings means measuring every program all the time, not just
while the Apps tab is open, so turning it on keeps the sampler described below
running in the background — a few percent of one core.

### Being told without looking

A ⚠️ only helps if you are looking at it. Three switches, all off to begin
with, let Gauge speak up instead. The first is in the App alerts card, beside
the limits it uses; the other two are in **Settings > Notifications**:

| | When it speaks |
| --- | --- |
| Notify when one stays over a limit | it has been over for the time you set, 1–30 minutes, default 5 |
| Disk space runs low | less than 10 GB free |
| The Mac is hot enough to slow down | macOS reports *serious* or *critical* thermal pressure |

Two rules keep this from becoming the thing you learn to ignore:

- **Sustained, never instantaneous.** A limit crossed for one reading is an app
  starting up. The same limit held for five minutes is worth knowing. If a
  program settles down and gets busy again, the clock starts over.
- **Said once.** Having mentioned a program, Gauge stays quiet about that one
  for an hour however long it carries on. The Apps tab has the running total
  for anyone who wants it.

Turning the first switch on asks macOS for permission the first time. Nothing
asks at launch. If macOS is blocking notifications, the card says so and offers
a button straight to the right pane of System Settings.

Switching on **Notify when one stays over a limit** means watching every program all
the time, panel open or shut, which costs a few percent of one core — exactly
the same bargain as the menu bar warning count below. The other two switches are
free: that data is already being read for the Overview.

### Health alerts

**Settings > Health alerts** has a switch and a limit for each part of the Mac
that reports its own wear:

| | Default limit | Range |
| --- | --- | --- |
| Battery health drops below | 80% | 50% – 95% |
| Drive health drops below | 50% | 10% – 95% |

Below the limit, Gauge sends a notification, then a reminder once a week while
it stays there — worn parts do not get better, so an hourly reminder would only
be nagging. That memory is kept across restarts, so a worn battery is not
announced afresh at every login. Switching an alert on, or moving its limit,
lets it speak at once, so you find out straight away if a part is already past
it. A drive that raises its own alarm is mentioned immediately whatever its
percentage.

The battery figure is the one macOS itself reports, the same as System
Settings > Battery > Battery Health. 80% is Apple's own line for a worn
battery. The battery's measuring chip also reports raw milliamp-hours, which
can read a few points lower; both are on the Power Inspect page.

Settings only holds the switches and limits. The parts' actual health is on
the Overview and the Inspect pages.

### Where these numbers come from, and what they cost

No single source has all four, so the tab merges two:

| Figure | Source |
| --- | --- |
| CPU, energy impact, RAM | `top`, left running |
| GPU | the IOKit registry, read directly |

The GPU figure is the interesting one. Every program that uses the graphics chip
leaves a record in the registry naming its process and adding up how long it
has had the GPU, in nanoseconds. Two readings and the time between them give a
percentage. Nothing needs special permission.

Left running and printing every two seconds, `top` costs about 3% of one core.
It only runs while the Apps tab is open or the App alerts readout is on, and
stops the moment neither is. Gauge hides its own helper from the list. If Gauge
is killed outright, with no chance to tidy up, `top` still exits on its own the
next time it tries to write to a reader that is gone.

The tab used to have a per-app **Network** column, which came from a second
tool, `nettop`. It was swapped for RAM, which `top` was already reporting, so
the swap also removed that tool and the processor time it used.

Names come from the kernel rather than from `top`, which clips them to about
fifteen characters. One subtlety: a process can replace the program it is
running while keeping its process number — a shell does it every time it starts
a command — so a remembered name is only trusted while `top` still reports the
same program under that number. Before that check, a download started from a
script was labelled "zsh" for as long as it ran.

## Two things worth knowing about Apple Silicon

**There is no GPU temperature.** On an Apple Silicon Mac the CPU and the GPU are
two areas of the same piece of silicon, and macOS publishes the sensor readings
without saying which part of the chip each one sits over. Any app that shows you
a separate "GPU temperature" on these Macs is guessing. Gauge reports the hottest
sensor on the die and calls it the chip temperature, which is the honest version
of the same number, and lists every individual sensor in the Sensors tab so you
can see the raw data yourself.

**This Mac has no fans.** A MacBook Air cools itself passively, so there is no
fan speed to report and Gauge does not offer it.

## The menu bar is smaller than you think

The menu bar has very little free space, especially on a Mac with a notch — the
display cannot draw anything behind it, so every status item competes for the
strip to its right. When they do not all fit, macOS hides the overflow behind a
`«` chevron, and your Gauge readout is the one that disappears.

Measured on this Mac with its current set of menu bar items:

| Style | 3 readings | 5 readings |
| --- | --- | --- |
| Icons | 152 pt | 259 pt — hidden |
| Values only | ~100 pt | 169 pt — fits |

So if a reading vanishes from the menu bar, you have not broken anything: you
have run out of room. Switch **Appearance** to *Values only* in Settings, which
drops the icons and roughly doubles how many fit.

## How the code is laid out

```
Tools/
  MakeIcon.swift          draws the app icon; run via make-icon.sh
Sources/
  main.swift              the app's entry point, about twenty lines
  Model/
    Snapshot.swift        one complete reading of the machine
    Metric.swift          the fourteen readings, and how each is formatted
    MetricsEngine.swift   the timer that takes a reading and publishes it
    Preferences.swift     what you chose, remembered between launches
    LaunchAtLogin.swift   the login item, asked of macOS rather than stored
    History.swift         a short rolling window of past readings, per series
    HistoryArchive.swift  the same readings kept on disk, a point a minute
    AlertWatcher.swift    decides when something is worth interrupting you for
    Inspector.swift       gathers every fact for the Inspect pages
    OverviewDetail.swift  the lines each Overview section can list
    SystemNotifier.swift  hands a message to Notification Centre
    SystemInfo.swift      the facts about this Mac that never change
  Sensors/                one file per source of numbers
    ProcessInspector.swift  one program's path, owner and start time
    HealthSampler.swift     each drive's own NVMe health log
  UI/
    StatusItemController.swift   the menu bar item
    DetailPanel.swift            the four tabs
    InspectPage.swift            the Inspect pages, and the range buttons
    Charts.swift                 rings, trend lines, stacked bars, palette
    Widgets.swift                small pieces the panel reuses
```

The shape to notice: **nothing in the user interface talks to a sensor.** Each
sampler produces a piece of a `Snapshot`, the engine assembles one every couple
of seconds and hands it to the main thread, and the whole interface reads from
that single value. So there is only ever one answer on screen to "what is the
CPU doing right now", and reading a slow sensor can never make the menu bar
stutter, because sampling happens on a background queue.

`AlertWatcher` and `SystemNotifier` are deliberately two files rather than
one. Deciding *whether* to say something is full of rules worth testing —
sustained for how long, said how often, reset when — and testing them should
not involve putting banners on screen. So the watcher calls a closure, and only
`SystemNotifier` knows what Notification Centre is.

To add a new reading you touch two places: add a case to `Metric`, and add the
line that formats it in `Metric.value(from:fahrenheit:)`. The settings list and
the menu bar both build themselves from `Metric.allCases`, so a new case appears
in both without any further work.

### Where the numbers come from

| Reading | Source |
| --- | --- |
| CPU usage | `host_processor_info` — per-core tick counters |
| Memory | `host_statistics64`, plus `vm.swapusage` |
| Temperatures | the IOKit HID event system (see below) |
| GPU | the `PerformanceStatistics` dictionary in the IOKit registry |
| Disk space / activity | `URLResourceValues`, and `IOBlockStorageDriver` |
| Network rates | interface counters via `sysctl`, allowing for them wrapping every 4 GB |
| Network totals since startup | `netstat`, once a minute (see below) |
| Drive health | the drive's own NVMe health log, via `NVMeSMARTLib.plugin` |
| Inspect pages | `Inspector`, gathering on demand: `sysctl`, the IO registry, Metal, SystemConfiguration |
| Battery | `IOPSCopyPowerSourcesInfo`, plus `AppleSmartBattery` |
| Per-app figures | `top` and the IOKit registry (see *The Apps tab*) |
| A program's path, owner and start time | `proc_pidpath`, and `sysctl` for the kernel's process table |
| Saved history | Gauge's own file, `~/Library/Application Support/Gauge/history.csv` |
| Model name | `system_profiler`, once at launch |
| GPU cores, chip, cores, RAM | `sysctl` and the IOKit registry |
| Thermal pressure | `ProcessInfo.thermalState` |
| Volumes, link speed, IP | `URLResourceValues` and `getifaddrs` |

One oddity worth knowing: the graphics driver reports utilisation as a figure
accumulated since the last time anything asked. If a second monitoring app is
polling the GPU at the same time, the two of you split the reading and both get
a jagged line. Gauge is fine on its own; it is only running two GPU monitors at
once that misleads.

Most of those are ordinary documented calls. Temperatures are the exception, and
worth explaining, because it is the one genuinely awkward part of the app.

macOS exposes the thermal sensors through the HID event system — the same
machinery behind the trackpad. The five functions that walk it are exported from
IOKit but are in no public header, so `TemperatureSampler` looks them up by name
at launch with `dlsym`. Two consequences:

- If a future macOS withdraws any of them, the lookup fails, the sampler refuses
  to initialise, and the app carries on without temperatures instead of crashing.
- Every sensor handle stays an opaque raw pointer. Swift's automatic reference
  counting would otherwise try to retain and release objects whose ownership
  rules it cannot see, which corrupts memory. The one reference the app does
  take is deliberate and explicit, in the initialiser.

Of the 47 sensors this Mac reports, about 41 are real. The rest are unused
channels reading far below freezing, and calibration channels pinned to a fixed
value. Both are filtered out.

### Why network totals come from netstat

macOS hands ordinary apps a cut-down copy of each connection's traffic
counters: 32 bits wide, so they wrap back to zero every 4 GB, and with the
hardware address blanked to `02:00:00:00:00:00`. Until this was found, Gauge's
"received since the Mac started" quietly restarted from nothing after every 4
GB — it read 238 MB on a Mac that had actually received 8.8 GB. `netstat`
carries a private Apple permission that sees the full figures, so once a minute
Gauge asks it for them, and in between adds on each tick's traffic, recognising
a wrap as traffic rather than mistaking it for zero. Hardware addresses stay
hidden even through `netstat` when an app is the one asking, so the Network
page leaves them out rather than show the blank.

`netstat` only ever runs in the background, alongside the other samplers, and
its answer is handed to the Network page with each reading. An earlier version
ran it while drawing the page, and it crashed Gauge: waiting for another
program lets the Mac carry on with other work in the meantime, including
drawing the panel again, and SwiftUI aborts when it is asked to draw something
it is still in the middle of drawing.

## The icon

`Tools/make-icon.sh` redraws it. The artwork is not an image file — it is drawn
in code in `Tools/MakeIcon.swift`, so it stays sharp at every size and is
adjusted by changing numbers rather than reopening an editor. The script renders
all ten sizes and packs them into `Resources/AppIcon.icns`; `build.sh` just
copies that into the bundle.

Two things about it are deliberate.

**The artwork fills the whole square.** On macOS 26 and later the system rounds
icons to its own shape. The traditional approach — draw a rounded square, leave
a transparent margin around it — was right for years and is wrong now: the
system reads it as a small image and draws its own dark tile behind it, giving
you one rounded square nested inside another. Filling the canvas edge to edge
lets the system simply mask it.

That failure is invisible if you only look at the `.icns`, which looks perfect
either way. The way to check is to ask the system what it would actually draw:

```bash
swift -e 'import AppKit; let i = NSWorkspace.shared.icon(forFile: "/Applications/Gauge.app"); print(i.representations.count)'
```

`NSWorkspace.icon(forFile:)` is the same call Finder and Spotlight make, so
rendering its result to a PNG shows the system's treatment rather than the file.

**The small sizes are drawn differently.** Below 64px the dial uses a thicker
arc and a shorter, fatter needle, because at 16px a faithful scaled-down copy
turns into mud. Same shape, fewer details.

If you change the icon and macOS keeps showing the old one, it is cached by
path. `build.sh` already runs `touch` and `lsregister -f` after installing,
which is usually enough.

## Building

`build.sh` compiles with `swiftc` directly — no Xcode project, no packages, no
dependencies. It then installs to `/Applications` and relaunches. Three things
in it are not obvious:

- It pins the **macOS 26 SDK**. The Command Line Tools here ship a Swift 6.3
  compiler next to a macOS 27 SDK that wants 6.4, and those two refuse to work
  together.
- It assembles and signs the bundle in a temporary folder, then installs it with
  `ditto --noextattr`. This folder is inside iCloud Drive, which attaches its own
  file attributes to anything written here, and `codesign` refuses to sign a
  bundle carrying them.
- It quits any running copy before installing, because macOS will not let you
  replace a bundle that is currently executing.
