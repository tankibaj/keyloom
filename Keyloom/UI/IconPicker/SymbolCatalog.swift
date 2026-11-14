import Foundation

struct SymbolEntry: Equatable, Sendable {
    let name: String
    let keywords: [String]

    /// What VoiceOver reads and a person would say: the name without its dots.
    var label: String { name.replacingOccurrences(of: ".", with: " ") }
}

struct SymbolSection: Equatable, Identifiable, Sendable {
    let title: String
    let symbols: [SymbolEntry]

    var id: String { title }
}

/// A curated, categorized list of SF Symbols for the icon picker. There is no public API that lists every
/// symbol, and reading the private CoreGlyphs files is not allowed, so the catalog is ours: names that exist
/// on every macOS this app supports, each with a few search words so "mail" finds `envelope`. A test checks
/// that every name resolves on the running system and that none repeats.
enum SymbolCatalog {
    static let sections: [SymbolSection] = [
        section("COMMUNICATION", """
        text.bubble message chat text
        bubble.left chat message talk
        envelope mail email letter message
        envelope.open mail email read
        envelope.badge mail unread notification
        paperplane send mail message
        phone call telephone
        phone.arrow.up.right call outgoing
        video camera call facetime
        mic microphone voice record
        megaphone announce broadcast
        bell notification alert reminder
        bell.slash mute silent
        quote.bubble quote reply
        ellipsis.bubble typing chat
        at mention email address
        number hashtag pound
        tray inbox mail
        tray.full inbox mail
        tray.and.arrow.down inbox download receive
        tray.and.arrow.up outbox upload send
        """),
        section("PEOPLE", """
        person user account profile
        person.fill user account profile
        person.2 people group team
        person.3 people group team crowd
        person.crop.circle user avatar profile
        person.crop.circle.fill user avatar profile
        person.badge.plus add user invite
        person.badge.key user login credential
        person.text.rectangle id card badge
        figure.wave hello greeting wave
        figure.run running exercise
        hand.raised hand stop wave
        hand.thumbsup like approve good
        hand.thumbsdown dislike bad
        hand.wave hello goodbye
        face.smiling smile happy emoji
        brain mind think smart
        eye see view watch
        eye.slash hidden private
        ear hear listen
        """),
        section("OBJECTS", """
        doc document file paper
        doc.text document file note text
        doc.on.doc copy duplicate
        doc.on.clipboard paste clipboard
        note.text note memo
        list.bullet list items
        list.number list numbered
        checklist tasks todo
        signature sign autograph
        pencil edit write
        pencil.line write edit
        square.and.pencil compose write edit
        paintbrush brush art paint
        scissors cut
        paperclip attach attachment
        link link url chain
        bookmark save bookmark
        bookmark.fill save bookmark
        tag label price
        flag flag mark
        pin pin attach
        mappin pin place location
        folder folder files directory
        folder.fill folder files directory
        archivebox archive box storage
        trash delete bin
        books.vertical library books read
        book book read
        book.closed book read
        newspaper news press
        magazine magazine press
        graduationcap school education learn
        ruler measure
        lightbulb idea light tip
        lightbulb.fill idea light tip
        key key password access
        lock lock secure private
        lock.open unlock open
        shield shield protect security
        checkmark.shield secure verified
        wrench tool fix repair
        hammer tool build
        screwdriver tool fix
        gearshape settings preferences gear
        slider.horizontal.3 settings controls filters
        magnifyingglass search find
        binoculars search look
        puzzlepiece plugin extension piece
        gift present birthday
        balloon party birthday celebrate
        party.popper party celebrate
        trophy win award prize
        medal award prize badge
        crown king vip premium
        umbrella rain weather
        sparkles magic new shine
        wand.and.stars magic wizard
        cube box 3d object
        shippingbox package parcel delivery
        bed.double sleep bedroom
        sofa furniture living room
        """),
        section("DEVICES", """
        iphone phone mobile
        ipad tablet
        laptopcomputer laptop computer macbook
        desktopcomputer desktop computer imac
        display monitor screen
        keyboard typing keys
        computermouse mouse pointer
        printer print
        headphones audio music listen
        airpods earbuds audio
        hifispeaker speaker audio sound
        tv television screen
        applewatch watch wearable
        gamecontroller game play controller
        camera photo picture
        video.fill video movie film
        externaldrive storage disk backup
        internaldrive storage disk
        opticaldisc disc cd dvd
        cpu processor chip
        network network connection
        wifi wifi wireless internet
        wifi.router router internet
        powerplug plug power
        speaker.wave.2 sound volume audio
        """),
        section("MAPS", """
        house home building
        house.fill home building
        building office company
        building.2 office company city
        building.columns bank museum government
        storefront shop store retail
        map map directions
        mappin.and.ellipse location place
        location location gps
        location.north navigation compass
        signpost.right directions sign
        globe world earth internet
        globe.europe.africa world earth europe
        globe.americas world earth america
        globe.asia.australia world earth asia
        flag.checkered finish race
        tent camp outdoor
        mountain.2 hiking nature
        beach.umbrella vacation holiday beach
        door.left.hand.open door entrance
        fuelpump fuel gas station
        """),
        section("TRANSPORT", """
        car car vehicle drive
        car.fill car vehicle drive
        bus bus public transport
        tram tram train
        train.side.front.car train rail
        airplane plane flight travel
        airplane.departure plane flight takeoff
        airplane.arrival plane flight landing
        ferry boat ship
        sailboat boat sail
        bicycle bike cycling
        motorcycle motorbike
        truck.box truck delivery shipping
        box.truck truck delivery
        fuelpump.fill fuel gas
        steeringwheel drive car
        """),
        section("NATURE", """
        leaf plant nature green
        leaf.fill plant nature green
        tree tree nature forest
        tree.fill tree nature forest
        camera.macro flower plant
        pawprint animal pet paw
        dog dog pet animal
        cat cat pet animal
        bird bird animal
        fish fish animal
        mountain.2.fill mountain nature
        water.waves water sea waves
        drop water rain liquid
        flame fire hot burn
        snowflake snow cold winter
        wind wind air breeze
        sun.max sun sunny day
        moon moon night
        moon.stars night sleep stars
        star star favorite rating
        star.fill star favorite rating
        sparkle shine star new
        bolt lightning power energy
        bolt.fill lightning power energy
        atom science physics
        """),
        section("WEATHER", """
        sun.min sun morning
        sun.horizon sunrise sunset
        sunrise sun morning
        sunset sun evening
        cloud cloud weather
        cloud.fill cloud weather
        cloud.rain rain weather
        cloud.heavyrain rain storm weather
        cloud.bolt thunder storm weather
        cloud.snow snow weather
        cloud.fog fog mist weather
        cloud.sun cloudy sunny weather
        cloud.moon cloudy night weather
        tornado storm wind
        thermometer temperature heat
        thermometer.medium temperature heat
        thermometer.snowflake cold temperature
        rainbow rainbow colors
        """),
        section("COMMERCE", """
        creditcard credit card payment pay
        creditcard.fill credit card payment pay
        banknote money cash payment
        dollarsign money currency price
        eurosign money currency euro price
        cart cart shopping buy
        cart.fill cart shopping buy
        basket shopping basket buy
        bag shopping bag buy
        handbag shopping bag
        giftcard gift card voucher
        receipt invoice bill
        shippingbox.fill package parcel delivery
        barcode barcode scan price
        qrcode qr code scan
        percent discount sale
        tag.fill label price sale
        chart.line.uptrend.xyaxis growth profit sales
        chart.bar chart statistics report
        chart.bar.fill chart statistics report
        chart.pie chart share statistics
        chart.xyaxis.line chart analytics
        wallet.pass wallet payment pass
        building.columns.fill bank finance
        briefcase briefcase work business
        briefcase.fill briefcase work business
        case work business
        doc.plaintext invoice contract
        cube.box packaging product
        storefront.fill shop store retail
        """),
        section("HEALTH", """
        heart heart love health
        heart.fill heart love health
        heart.circle heart health
        waveform.path.ecg heartbeat ecg health
        cross health medical hospital
        cross.case medical doctor first aid
        cross.case.fill medical doctor first aid
        stethoscope doctor medical
        pills medicine drugs tablet
        pill medicine drug tablet
        syringe injection vaccine
        bandage injury first aid
        lungs breathing health
        bed.double.fill sleep rest
        figure.mind.and.body yoga meditation wellness
        figure.walk.circle activity steps
        figure.strengthtraining.traditional gym workout
        figure.yoga yoga exercise
        dumbbell gym workout
        drop.fill water hydration blood
        medical.thermometer fever temperature
        facemask mask health
        heart.text.square.fill care health
        waveform.path heartbeat pulse
        """),
        section("MATH", """
        plus add more
        minus subtract less
        multiply times cross
        divide division
        equal equals same
        plusminus plus minus
        lessthan less than smaller
        greaterthan greater than bigger
        sum sum total sigma
        function function formula
        pi pi math
        angle angle geometry
        triangle triangle shape
        1.circle one number
        2.circle two number
        3.circle three number
        4.circle four number
        5.circle five number
        6.circle six number
        infinity infinite forever
        wave.3.right frequency
        """),
        section("TEXT", """
        textformat text font type
        textformat.size text size font
        bold bold text
        italic italic text
        underline underline text
        strikethrough strikethrough text
        text.alignleft align left
        text.aligncenter align center
        text.alignright align right
        text.justify justify align
        text.quote quote blockquote
        text.cursor cursor caret input
        character.cursor.ibeam cursor caret input
        list.dash list items
        list.bullet.indent list indent
        paragraphsign paragraph
        quote.opening quote start
        quote.closing quote end
        textbox text box field
        abc letters alphabet
        character letters
        doc.text.magnifyingglass find document search
        curlybraces code braces
        chevron.left.forwardslash.chevron.right code html
        terminal terminal command shell
        apple.terminal terminal command
        """),
        section("TIME", """
        clock clock time
        clock.fill clock time
        clock.badge.checkmark time done
        clock.arrow.circlepath history recent undo
        alarm alarm wake
        timer timer countdown
        stopwatch stopwatch time
        hourglass hourglass wait time
        hourglass.bottomhalf.filled hourglass wait
        calendar calendar date schedule
        calendar.badge.plus calendar add event
        calendar.badge.clock calendar schedule
        calendar.day.timeline.left agenda schedule
        calendar.circle calendar date
        bell.badge reminder alert
        speedometer speed fast
        moon.zzz sleep night
        zzz sleep
        repeat repeat loop
        arrow.clockwise.circle refresh repeat
        """),
        section("MEDIA", """
        play play start
        play.fill play start
        pause pause
        stop stop
        record.circle record
        forward forward next skip
        backward backward previous
        shuffle shuffle random
        repeat.1 repeat loop once
        music.note music song
        music.note.list playlist music
        music.mic karaoke sing
        waveform audio sound wave
        speaker speaker audio
        speaker.slash mute audio
        film film movie
        movieclapper movie film
        photo photo picture image
        photo.on.rectangle photos pictures gallery
        camera.fill camera photo
        camera.viewfinder scan camera
        ticket ticket event
        sportscourt sport field
        basketball sport ball
        soccerball sport football
        tennisball sport tennis
        baseball sport ball
        football sport american
        gamecontroller.fill game play
        dice dice game random
        mic.fill microphone voice record
        rectangle.stack stack cards
        """),
        section("FOOD", """
        cup.and.saucer coffee tea drink
        mug coffee tea drink
        takeoutbag.and.cup.and.straw takeaway food drink
        fork.knife food restaurant meal
        fork.knife.circle food restaurant
        wineglass wine drink
        waterbottle water drink
        birthday.cake cake birthday
        carrot vegetable food
        """),
        section("ARROWS", """
        arrow.up up
        arrow.down down
        arrow.left left
        arrow.right right
        arrow.up.right diagonal open external
        arrow.down.right diagonal
        arrow.uturn.left undo back
        arrow.uturn.right redo forward
        arrow.clockwise refresh reload
        arrow.counterclockwise refresh undo
        arrow.triangle.2.circlepath sync refresh
        arrow.triangle.branch branch fork git
        arrow.triangle.merge merge git
        arrow.up.arrow.down sort swap
        arrow.left.arrow.right swap exchange
        arrow.up.doc upload file
        arrow.down.doc download file
        arrow.up.circle upload
        arrow.down.circle download
        square.and.arrow.up share export
        square.and.arrow.down save import
        arrow.turn.down.right reply indent
        arrowshape.turn.up.right forward share
        arrowshape.turn.up.left reply back
        chevron.up up
        chevron.down down
        chevron.left left back
        chevron.right right next
        return return enter
        """),
        section("SHAPES", """
        circle circle round
        circle.fill circle round dot
        square square box
        square.fill square box
        rectangle rectangle
        rectangle.fill rectangle
        triangle.fill triangle
        diamond diamond rhombus
        diamond.fill diamond rhombus
        pentagon pentagon shape
        hexagon hexagon shape
        octagon octagon stop shape
        oval oval shape
        capsule capsule pill shape
        seal seal badge
        seal.fill seal badge
        star.circle star badge
        star.square star badge
        app app square
        app.badge app notification
        square.grid.2x2 grid apps
        square.grid.3x3 grid apps
        circle.grid.3x3 dots grid
        target target goal aim
        scope target aim focus
        """),
        section("SYMBOLS", """
        checkmark check done yes
        checkmark.circle check done yes
        checkmark.circle.fill check done yes
        checkmark.seal check verified approved
        checkmark.seal.fill check verified approved
        xmark close no cancel
        xmark.circle close no cancel
        xmark.circle.fill close no cancel
        exclamationmark warning important alert
        exclamationmark.circle warning important
        exclamationmark.triangle warning caution
        exclamationmark.triangle.fill warning caution
        questionmark question help
        questionmark.circle question help
        info.circle info information
        plus.circle add new
        plus.circle.fill add new
        minus.circle remove delete
        nosign forbidden no prohibited
        hand.raised.fill stop block
        lifepreserver help support
        bolt.circle power quick
        bolt.shield security power
        wand.and.rays magic effect
        flag.fill flag mark
        flag.circle flag mark
        bookmark.circle save
        pin.fill pin attach
        hand.tap tap touch
        text.badge.checkmark approved text
        ellipsis more menu
        ellipsis.circle more menu
        line.3.horizontal menu hamburger
        slider.horizontal.below.rectangle adjust edit
        command command shortcut mac
        shift shift
        number.circle number
        rosette award ribbon
        """),
    ]

    static var allNames: [String] { sections.flatMap { $0.symbols.map(\.name) } }

    /// The sections that still have a symbol after the query is applied: every whitespace-separated term must
    /// appear in the symbol's name or one of its keywords (case-insensitive). A blank query keeps everything.
    static func sections(matching query: String) -> [SymbolSection] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return sections }
        return sections.compactMap { section in
            let hits = section.symbols.filter { entry in
                let haystack = [entry.name.lowercased()] + entry.keywords
                return terms.allSatisfy { term in haystack.contains { $0.contains(term) } }
            }
            return hits.isEmpty ? nil : SymbolSection(title: section.title, symbols: hits)
        }
    }

    /// One line per symbol: its name, then its search words.
    private static func section(_ title: String, _ lines: String) -> SymbolSection {
        let symbols = lines.split(separator: "\n").compactMap { line -> SymbolEntry? in
            let words = line.split(separator: " ").map(String.init)
            guard let name = words.first else { return nil }
            return SymbolEntry(name: name, keywords: words.dropFirst().map { $0.lowercased() })
        }
        return SymbolSection(title: title, symbols: symbols)
    }
}
