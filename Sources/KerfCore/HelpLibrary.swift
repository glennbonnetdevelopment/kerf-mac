import Foundation

/// One piece of a help topic. Text may use inline Markdown (**bold**, *italic*).
public enum HelpBlock: Hashable, Sendable {
    /// A sub-heading inside a topic.
    case heading(String)
    /// A paragraph.
    case text(String)
    /// Numbered steps to follow in order.
    case steps([String])
    /// Unordered points.
    case bullets([String])
    /// A highlighted hint.
    case tip(String)
    /// A highlighted warning.
    case warning(String)
    /// Keyboard shortcuts or mouse actions: (keys, what they do).
    case keys([HelpKey])
}

public struct HelpKey: Hashable, Sendable {
    public var keys: String
    public var action: String
    public init(_ keys: String, _ action: String) {
        self.keys = keys
        self.action = action
    }
}

/// A help page about one feature or workflow.
public struct HelpTopic: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// SF Symbol shown in the topic list.
    public var symbol: String
    /// One line shown under the title.
    public var summary: String
    public var blocks: [HelpBlock]

    public init(id: String, title: String, symbol: String, summary: String, blocks: [HelpBlock]) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.summary = summary
        self.blocks = blocks
    }

    /// Every word in the topic, lowercased, for searching.
    public var searchText: String {
        var parts = [title, summary]
        for block in blocks {
            switch block {
            case .heading(let s), .text(let s), .tip(let s), .warning(let s): parts.append(s)
            case .steps(let list), .bullets(let list): parts += list
            case .keys(let list): parts += list.flatMap { [$0.keys, $0.action] }
            }
        }
        return parts.joined(separator: " ").lowercased()
    }

    /// True when every word of the query appears somewhere in the topic.
    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = searchText
        return words.allSatisfy { haystack.contains($0) }
    }
}

/// The in-app help, shown by Help › KerfKutter Help.
///
/// To document a new feature, add a `HelpTopic` to `topics` (or add blocks to the topic it belongs in).
/// Topics appear in the help window in this order. Keep the wording in step with the labels in the app.
public enum HelpLibrary {
    public static func topic(_ id: String) -> HelpTopic? {
        topics.first { $0.id == id }
    }

    public static func search(_ query: String) -> [HelpTopic] {
        topics.filter { $0.matches(query) }
    }

    public static let topics: [HelpTopic] = [
        gettingStarted,
        importing,
        drawing,
        text,
        arrange,
        layers,
        materials,
        laser,
        vinyl,
        panels,
        cnc,
        printAndCut,
        embroidery,
        devices,
        previewExport,
        shortcuts,
        safety,
    ]

    // MARK: - Topics

    static let gettingStarted = HelpTopic(
        id: "getting-started", title: "Getting started", symbol: "sparkles",
        summary: "The window, and the path from artwork to a finished job.",
        blocks: [
            .text("KerfKutter designs and runs jobs on GRBL laser engravers, vinyl cutters and GRBL CNC routers, and exports embroidery files for Brother, Janome and Tajima machines."),
            .heading("The window"),
            .bullets([
                "**Toolbar** (top): Import, Image, the toolpath **Preview** switch, and the **Device** picker that chooses the machine you're working for.",
                "**Drawing tools** (above the canvas): select, edit nodes, measure, basic shapes, the shapes library, text, text around a shape, curved text, contour cut, colour swatches and units.",
                "**Canvas**: the machine's bed, drawn to scale with a grid and rulers.",
                "**Sidebar** (right): the **Layers**, **Arrange** and **Machine** tabs.",
            ]),
            .heading("A typical job"),
            .steps([
                "Pick your machine in the **Device** picker. The canvas resizes to its bed.",
                "Import artwork with **File › Import** (⌘I), drag files onto the window, or draw with the tools above the canvas.",
                "In **Layers**, give each colour a mode (Line, Fill, Image, Cut, Mill or Print only) and its speed, power or force. A saved material can fill these in for you.",
                "Switch on **Preview** to check the cutting order, travel moves and estimated time.",
                "Open the **Machine** tab to connect and run the job, or use **File › Export Machine File** (⌘E) to save it for another program.",
            ]),
            .tip("Save your work as a KerfKutter project with **File › Save** (⌘S). It keeps artwork, layers and settings together."),
        ])

    static let importing = HelpTopic(
        id: "importing", title: "Importing artwork", symbol: "square.and.arrow.down",
        summary: "SVG, DXF, LightBurn and Easy Cut files, and images to engrave.",
        blocks: [
            .heading("Vector artwork"),
            .text("Choose **File › Import SVG, DXF, LightBurn or Easy Cut…** (⌘I) or the **Import** toolbar button."),
            .bullets([
                "**SVG**: paths, basic shapes and transforms, at their real-world size.",
                "**DXF**: lines, arcs, circles, ellipses, polylines (with bulges) and splines.",
                "**LightBurn** (.lbrn2, .lbrn): layers with their settings, shapes, images and text.",
                "**Easy Cut Pro, Easy Sign Cut Pro, Sure Cuts A Lot** (.esc5, .scut5): whatever shapes can be read. Anything that can't be brought across is listed after the import.",
            ]),
            .text("Each colour in the artwork becomes its own layer, so you can give each one different settings."),
            .heading("Images"),
            .text("Choose **File › Import Image to Engrave…** (⇧⌘I) or the **Image** toolbar button. PNG, JPEG, TIFF, BMP, GIF and HEIC images go on an **Image** layer, where you choose dithering and power (see Layers and cut settings)."),
            .tip("You can also drag SVG, DXF, project and image files straight onto the window."),
        ])

    static let drawing = HelpTopic(
        id: "drawing", title: "Drawing and editing", symbol: "pencil.and.outline",
        summary: "Selecting, moving, scaling and reshaping artwork on the canvas.",
        blocks: [
            .heading("Tools"),
            .bullets([
                "**Select** (arrow): click a shape, Shift-click to add or remove, or drag a box around shapes. Drag a selection to move it, drag a corner or edge handle to scale, and drag the rotate handle to turn it.",
                "**Edit nodes**: drag a node to reshape a path. Option-click a node to delete it, or Option-click the outline to add one.",
                "**Measure** (ruler): drag between two points to read the distance. Hold Shift to snap to 45°.",
                "**Rectangle, Ellipse, Line**: drag on the canvas. Hold Shift for equal width and height.",
                "**Shapes library** (star): choose a star, polygon, rounded rectangle, triangle, diamond, heart, arrow, cross, starburst, gear, crescent or ring, set its points, sides, teeth or corner radius, then drag a box on the canvas.",
            ]),
            .heading("Moving around"),
            .keys([
                HelpKey("Two-finger scroll", "Pan the canvas"),
                HelpKey("Option-drag", "Pan the canvas"),
                HelpKey("Pinch, or ⌘-scroll", "Zoom"),
                HelpKey("Mouse wheel", "Zoom"),
            ]),
            .heading("Nudging and snapping"),
            .keys([
                HelpKey("Arrow keys", "Nudge the selection 1 mm"),
                HelpKey("⇧ + arrow keys", "Nudge 10 mm"),
                HelpKey("⇧ while scaling", "Keep proportions"),
                HelpKey("⇧ while rotating", "Snap to 15° steps"),
            ]),
            .heading("Colours and units"),
            .text("Click a colour swatch above the canvas, or use the colour well, to move the selection onto that colour's layer. The **mm / in** switch sets the units for the grid, rulers, measurements and size fields. Files and settings are always stored in millimetres."),
        ])

    static let text = HelpTopic(
        id: "text", title: "Text", symbol: "textformat",
        summary: "Adding text, text around a shape, and arched text.",
        blocks: [
            .steps([
                "Choose the **Text** tool and type in the box next to it.",
                "Pick a font and a cap height in mm.",
                "Click the canvas to place the text. It becomes outlines that cut like any other shape.",
            ]),
            .text("To change text later, choose the Text tool and click the text, or select it, then edit it in the toolbar."),
            .heading("Text around a shape"),
            .text("Select one shape and click **Text around shape** to lay the text along its outline. Tick **Inside** to put it inside the shape. Drag the text along the path to slide it, or use **Move to other side of path** in Arrange."),
            .heading("Curved text"),
            .text("Select one piece of text and click **Curve**. Positive angles bend it up into an arch, negative into a bowl, and 360° wraps it into a full circle. The Arch, Bowl, Circle and Straight buttons are quick presets."),
        ])

    static let arrange = HelpTopic(
        id: "arrange", title: "Arranging and combining", symbol: "square.on.square",
        summary: "Exact sizes, rotation, mirroring, booleans, nesting and the workpiece.",
        blocks: [
            .heading("Arrange tab"),
            .text("With shapes selected, the **Arrange** tab shows their exact position and size. Tick **Keep proportions** to scale evenly. Buttons rotate 90°, mirror, duplicate, delete and **Centre on bed**. The same commands are in the **Arrange** menu."),
            .heading("Combine"),
            .bullets([
                "**Weld** merges overlapping shapes into one outline.",
                "**Subtract** cuts the later shapes out of the first one.",
                "**Intersect** keeps only where the shapes overlap.",
                "**Exclude overlap** keeps everything except where they overlap.",
                "**Join open paths** links open lines whose ends meet, and **Break apart** splits a shape into its separate pieces.",
            ]),
            .heading("Nest"),
            .text("**Nest** packs shapes on the bed by their bounding boxes, tallest first, with the spacing you set. Tick **Allow 90° rotation** to let it turn pieces. With nothing selected it nests everything."),
            .heading("Workpiece"),
            .text("Turn on **Show a workpiece on the bed** to draw your stock, cutting mat, vinyl sheet or embroidery hoop at its real size. **Fit to artwork** sizes it around the design. Nest and Centre then use the workpiece instead of the whole bed, and the job's zero point can be set on it."),
        ])

    static let layers = HelpTopic(
        id: "layers", title: "Layers and cut settings", symbol: "square.3.layers.3d",
        summary: "Each layer is a colour with its own mode and machine settings.",
        blocks: [
            .text("Every shape sits on a layer. Layers run top to bottom, and the checkbox beside a layer includes it in jobs or leaves it out. Use **+** to add a layer and **Move selection here** to put selected shapes on the chosen layer."),
            .heading("Modes"),
            .bullets([
                "**Line**: the laser follows the outline. Use it to cut or score.",
                "**Fill**: engraves the inside of closed shapes with back-and-forth lines. Set the line interval, angle and whether it engraves in both directions.",
                "**Image**: engraves a photo or picture. Choose a dither (Threshold, Floyd–Steinberg, Atkinson, or Grayscale with variable power), min and max power, line interval (shown as DPI), overscan and invert.",
                "**Cut (vinyl)**: a vinyl cutter's blade follows the outline at the speed (cm/s) and force (g) you set.",
                "**Mill (CNC)**: a router cuts with the feed, plunge, spindle speed, depths and tool you set (see CNC routing).",
                "**Print only**: registration marks and printed artwork. These go into the print PDF and are never cut.",
            ]),
            .text("Laser layers also have **Passes**, **Speed** (mm/min), **Power** and **Air assist**. A mode that the current machine can't run is skipped and marked in orange."),
            .tip("Use the **Material** menu on a layer to apply saved settings, or to save this layer's settings as a new material."),
        ])

    static let materials = HelpTopic(
        id: "materials", title: "Material library", symbol: "books.vertical",
        summary: "Save, reuse and share settings that work for each material.",
        blocks: [
            .text("A material stores a layer's mode and all its settings, such as \"3 mm birch plywood, Cut\". Open the library with **View › Material Library** (⌥⌘L)."),
            .steps([
                "Set up a layer until it cuts the way you want.",
                "In the layer's Material menu choose **Save these settings as a material…** and give it a material, operation and notes.",
                "Next time, pick it from the layer's Material menu, or select it in the library and click **Apply to current layer**.",
            ]),
            .text("Materials belong to a machine type (laser, cutter or CNC). If you change a layer after applying a material it shows as edited, and **Update “…” with these settings** saves the changes back. The library can import and export materials files to share or back up, and can restore the built-in xTool starter settings."),
            .warning("Starter settings are a starting point. Test on a scrap of the same material first."),
        ])

    static let laser = HelpTopic(
        id: "laser", title: "Running a laser job", symbol: "flame",
        summary: "Connecting to a GRBL laser, setting the origin, framing and running.",
        blocks: [
            .heading("Connect"),
            .steps([
                "Plug the laser in by USB and pick it in the **Device** picker.",
                "In the **Machine** tab choose the serial port (click refresh if it isn't listed) and click **Connect**. Live status and position appear.",
                "Click **Home** if your machine has limit switches, or **Unlock** if GRBL reports an alarm.",
            ]),
            .heading("Where the job starts"),
            .text("**Zero point** chooses where the job's origin is:"),
            .bullets([
                "**Machine home (absolute)**: the design runs exactly where it sits on the canvas bed.",
                "**Work zero (user origin)**: jog to a spot on the material and press **Set origin here**.",
                "**Current head position**: the job starts wherever the head is when you press Start or Frame.",
            ]),
            .text("For the last two, the 3×3 grid picks which point of the job (or the workpiece) lines up with that origin."),
            .heading("Run"),
            .steps([
                "Use the jog pad to move the head (choose the step size). The centre button goes to the work origin.",
                "Click **Frame** to trace the job's outline with the laser off and check it fits the material.",
                "Click **Start**. **Pause**, **Resume** and **Stop** are beside it, with progress and elapsed time below.",
            ]),
            .text("Tick **Cut selected shapes only** to run, frame, preview and export just the selection. The **Console** shows what the machine reports and lets you send GRBL commands."),
            .heading("Rotary"),
            .text("For mugs and tumblers, turn on **Rotary attachment fitted** in the device editor and enter the roller or chuck details. Design height then wraps around the object."),
        ])

    static let vinyl = HelpTopic(
        id: "vinyl", title: "Vinyl cutting", symbol: "scissors",
        summary: "Sending to a cutter over USB serial or a printer queue, and weeding.",
        blocks: [
            .steps([
                "Pick your cutter in the **Device** picker and put the artwork on **Cut (vinyl)** layers.",
                "In the **Machine** tab, set **Send via** to the serial port or the cutter's printer queue.",
                "Check blade offset and overcut, then click **Send to cutter**.",
            ]),
            .bullets([
                "**Blade offset** corrects for the drag blade's tip trailing behind its centre, so corners come out sharp.",
                "**Overcut** runs a little past the start of each closed shape so it fully separates.",
                "Inner shapes are cut before outer ones so letters don't shift on the mat.",
                "**Weeding border** adds a rectangle around the design, with the margin you set, to make weeding easier.",
                "Signs bigger than the cutter can be cut as overlapping panels. See **Panel cutting (big signs)**.",
            ]),
            .tip("Cutters that appear as a USB printer (like the GCC Expert 24): add them in **System Settings › Printers** as a Generic PostScript printer, then choose that queue. KerfKutter sends raw cutter commands to it."),
            .text("Machines with no live connection, like the Brother ScanNCut, use **Export file…** to save an SVG that you load from a USB stick or the maker's app."),
        ])

    static let panels = HelpTopic(
        id: "panels", title: "Panel cutting (big signs)", symbol: "rectangle.split.3x1",
        summary: "Cutting a vinyl sign bigger than the cutter as overlapping panels, one at a time.",
        blocks: [
            .text("When a sign is wider or longer than your cutter, KerfKutter can split it into overlapping panels (tiling). You cut each panel on its own and line them up when you apply the vinyl."),
            .steps([
                "Pick your cutter, then in the **Machine** tab turn on **Split into panels** under **Panels (oversized signs)**.",
                "Set **Panel width** (across the vinyl) and **Panel length** (along the roll). Leave them at 0 to use the machine's full work area.",
                "Set the **Overlap**, for example 12 mm (about half an inch), so the panels sit on top of each other with no gap.",
                "Check the panels on the canvas: dashed outlines named A1, A2, B1 and so on, with the overlaps shaded.",
                "Pick a panel in the grid to preview it, load the vinyl, and click **Send panel A1**. KerfKutter ticks it off and moves on to the next panel.",
            ]),
            .bullets([
                "Panels are equal in size, cut row by row from **A1** at the top left. Rows are letters, columns are numbers.",
                "Each panel is moved so it starts at the cutter's origin, so load fresh vinyl at the same spot each time.",
                "**Alignment marks** cuts small crosshairs in the middle of each overlap, at the same spot on both panels. Lay one panel over the next so the crosshairs match. Marks are never placed on the artwork; if a seam has no clear spot, KerfKutter tells you.",
                "Weeding boxes and lines are added to each panel separately.",
                "**Export panels…** saves one file per panel, such as sign-A1.plt and sign-A2.plt, in a folder you choose.",
                "**Skip** moves on without sending, and **Start over** clears the ticks.",
            ]),
            .tip("A design that already fits the cutter is cut in one piece as usual, even with panels turned on."),
            .warning("Panels longer than the bed rely on the cutter feeding vinyl off the roll. Check that your cutter tracks straight over that length before cutting a long panel."),
        ])

    static let cnc = HelpTopic(
        id: "cnc", title: "CNC routing", symbol: "gearshape.2",
        summary: "Mill layers, inside and outside cuts, pockets, tabs and the wood preview.",
        blocks: [
            .text("Pick a GRBL CNC router (such as the SainSmart Genmitsu 4040 Pro) and put the artwork on **Mill (CNC)** layers."),
            .heading("Layer settings"),
            .bullets([
                "**Feed** and **Plunge** rates (mm/min), and the **Spindle** S value.",
                "**Cut depth** is the total depth; **Pass depth** is how deep each pass goes.",
                "**Tool diameter**, so cuts are offset by the right amount.",
                "**Milling** direction (Climb or Conventional), **Pocket stepover** and **Ramp length** for gentler plunges.",
            ]),
            .heading("Cut types"),
            .text("**Default cut** on the layer, or **CNC cut type** in Arrange for a single shape, chooses:"),
            .bullets([
                "**Auto**: outer shapes are parts and shapes inside them are holes.",
                "**Part (cut outside)** keeps the piece at its drawn size.",
                "**Hole (cut inside)** keeps the opening at its drawn size.",
                "**On the line**, **Pocket (clear inside)** and **Drill at centre**.",
            ]),
            .heading("Holding tabs"),
            .text("Turn on **Holding tabs on parts** to leave small bridges that stop parts coming loose on the last pass. Set how many per part and their width and height."),
            .heading("Before you cut"),
            .text("Jog the bit to the top of the stock and click **Zero Z**. The device's **Safe Z** is the height for travel moves. **Material Preview** (⌥⌘P, or the cube button on the toolbar) shows the carving on a block of wood so you can check it first."),
        ])

    static let printAndCut = HelpTopic(
        id: "print-and-cut", title: "Print and cut", symbol: "printer",
        summary: "Registration marks, printing, and cutting around printed artwork.",
        blocks: [
            .heading("Contour cut"),
            .text("**Contour cut** (above the canvas, or the Arrange menu) adds a cut line around the artwork, a set distance out. Images are outlined by their printed (non-white) pixels, and holes are skipped so each piece cuts out whole. The line goes on its own layer."),
            .heading("Registration marks"),
            .steps([
                "Choose the mark style, 3 or 4 corners, size and gap, then click **Add registration marks**. They go on a Print only layer.",
                "Use **File › Export Print PDF…** and print it.",
                "Load the printed sheet on the machine.",
            ]),
            .text("**On a laser**: jog the laser dot to the centre of each mark, click **Record mark 1** and **Record mark 2**, and turn on **Align job to marks**. The job is moved and rotated to match the sheet."),
            .text("**On a cutter**: load the sheet with mark 1 at the cutter's origin. Cutters with an optical mark sensor use their own alignment routine, which KerfKutter doesn't drive yet."),
        ])

    static let embroidery = HelpTopic(
        id: "embroidery", title: "Embroidery", symbol: "circle.hexagongrid",
        summary: "Turning artwork into stitches and exporting PES, JEF or DST files.",
        blocks: [
            .text("Open **File › Export Embroidery (PES, JEF, DST)…** (⌥⌘E). Each layer is one thread colour, sewn in layer order, and the design is centred in the hoop."),
            .steps([
                "Choose the format: **PES** (Brother), **JEF** (Janome) or **DST** (Tajima), and the hoop.",
                "Set each layer's stitch type, stitch length, density and pull compensation. The nearest thread from the machine's chart is shown beside each colour.",
                "Check the stitch preview, time to sew and number of trims, then click **Export**.",
            ]),
            .heading("Stitch types"),
            .bullets([
                "**Auto (digitize)**: picks running, satin or fill stitches from each shape's size.",
                "**Running stitch** and **Triple (bean) stitch** for outlines.",
                "**Satin border** for smooth edges, **Fill (tatami)** for areas.",
                "**Satin columns (lettering)** for text and narrow strokes.",
            ]),
            .text("**Underlay** stitches go down first to stabilise the fabric. **Group same colours** sews layers of the same thread together when nothing in between overlaps, for fewer thread changes."),
            .heading("Sewing order"),
            .text("**Optimize order** sews similar shapes together, nearest first. Turn it off to set the order yourself with the up and down arrows. Reorder whole colours in the Layers panel."),
            .heading("Hand tweaking"),
            .text("Select a shape and, in **Arrange › Embroidery**, tick **Own stitch settings** to sew it differently from its layer. **Edit stitches…** opens the stitch editor, where you can move, add and delete stitch points, split a run with a trim and jump, or join runs. Saved stitches sew exactly as edited; **Discard hand edits** goes back to automatic stitches."),
        ])

    static let devices = HelpTopic(
        id: "devices", title: "Machines and devices", symbol: "cpu",
        summary: "Adding a machine, its bed size, origin and connection settings.",
        blocks: [
            .text("Click the gear next to **Device** in the Machine tab to open the device editor. Add a machine from the presets, then check its settings against your machine."),
            .heading("Presets"),
            .bullets([
                "Lasers: xTool D1 Pro (with and without the extension kit), Creality Falcon2 12 W and 40 W, a K40-style CO2 laser, and a generic GRBL laser.",
                "CNC: SainSmart Genmitsu 4040 Pro.",
                "Cutters: GCC Expert 24, Redsail RS series, EasyCut-class USB cutters, Janome Artistic Edge 15 (experimental), and Brother ScanNCut 12×12 and 12×24 mats (SVG export).",
            ]),
            .heading("Settings"),
            .bullets([
                "**Work area**: bed width and height, where the origin is (front left, rear left and so on), and Swap X and Y.",
                "**Connection**: baud rate and flow control.",
                "**GRBL**: max S value ($30), rapid speed and receive buffer size. Lasers run with dynamic power (M4), so set laser mode ($32=1) on the controller.",
                "**Cutter**: HPGL, GP-GL or SVG file only, units per mm, blade offset, overcut, and whether to send speed and force.",
            ]),
            .warning("Preset bed sizes and origins are typical values. Check them against your own machine before the first job."),
        ])

    static let previewExport = HelpTopic(
        id: "preview-export", title: "Preview and export", symbol: "point.topleft.down.to.point.bottomright.curvepath",
        summary: "Checking the toolpath and saving machine files.",
        blocks: [
            .text("Switch on **Preview** in the toolbar to draw the toolpath in cutting order, with travel moves shown. The Machine tab shows the estimated job time."),
            .heading("Export"),
            .bullets([
                "**File › Export Machine File…** (⌘E): G-code (.gc) for lasers and CNC routers, or HPGL (.plt), GP-GL or SVG for cutters, depending on the device.",
                "**File › Export Print PDF…**: the print layers and artwork for print and cut.",
                "**File › Export Embroidery…** (⌥⌘E): PES, JEF or DST.",
            ]),
            .tip("A machine file can't know where the head will be, so a job set to start at the current head position is written from its zero point."),
        ])

    static let shortcuts = HelpTopic(
        id: "shortcuts", title: "Keyboard shortcuts", symbol: "keyboard",
        summary: "Menu shortcuts and canvas keys.",
        blocks: [
            .heading("File"),
            .keys([
                HelpKey("⌘N", "New"),
                HelpKey("⌘O", "Open"),
                HelpKey("⌘S", "Save"),
                HelpKey("⇧⌘S", "Save As"),
                HelpKey("⌘I", "Import SVG, DXF, LightBurn or Easy Cut"),
                HelpKey("⇧⌘I", "Import image to engrave"),
                HelpKey("⌘E", "Export machine file"),
                HelpKey("⌥⌘E", "Export embroidery"),
            ]),
            .heading("Edit and arrange"),
            .keys([
                HelpKey("⌘Z / ⇧⌘Z", "Undo / Redo"),
                HelpKey("⌘D", "Duplicate"),
                HelpKey("⌘⌫", "Delete"),
                HelpKey("⌘R / ⇧⌘R", "Rotate 90° clockwise / counter-clockwise"),
                HelpKey("⌥⌘W", "Weld"),
                HelpKey("⌘J", "Join open paths"),
                HelpKey("Arrows / ⇧ arrows", "Nudge 1 mm / 10 mm"),
            ]),
            .heading("Windows"),
            .keys([
                HelpKey("⌥⌘P", "Material Preview"),
                HelpKey("⌥⌘L", "Material Library"),
                HelpKey("⌘?", "KerfKutter Help"),
            ]),
        ])

    static let safety = HelpTopic(
        id: "safety", title: "Safety", symbol: "exclamationmark.triangle",
        summary: "Read this before running a laser or router.",
        blocks: [
            .warning("Lasers can start fires and damage eyes. Never leave a running laser unattended."),
            .bullets([
                "Wear eye protection rated for your laser's wavelength.",
                "Keep the **Stop** button, or your machine's emergency stop, within reach.",
                "Don't cut PVC, vinyl or other chlorine-containing materials with a laser. The fumes are toxic and corrode the machine.",
                "Use air assist and ventilation, and keep a fire extinguisher nearby.",
                "On a CNC router, clamp the stock firmly, wear eye and ear protection, and keep hands clear of the spindle.",
                "Frame every job first to make sure it fits the material.",
            ]),
        ])
}
