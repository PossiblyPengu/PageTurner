import Foundation

/// The word being said, and the line it is on, drawn by the page itself.
///
/// Readium's decorations look a mark's text up in the chapter every time one is put on the page, and build its
/// elements afresh: twice per spoken word (the word and its line), several times a second. Here the sentence is
/// found once — by its characters, spaces left out, inside the element it came from — and a word is then two
/// character counts into it: the page makes a range from them, measures it, moves two boxes that are already
/// there, and says in the same answer whether the word is on the page being shown.
///
/// The boxes sit in a container that looks like Readium's own (`data-group="tts-word"`, children carrying
/// `data-writing-mode`, the line first), so whatever asks the page where the voice's mark is finds either.
/// Anything this cannot do — a sentence the page spells otherwise, vertical writing — answers so, and the marks
/// are Readium's decorations as before.
enum SpokenMarkScript {
    /// What the page answers.
    enum Answer: String {
        /// The word is marked, and on the page being shown.
        case on
        /// Marked, on another page of the chapter.
        case off
        /// Not marked: the sentence or the word could not be found here.
        case missing = "none"
        /// The page does not hold this sentence (any more): it is to be given it.
        case stale
        /// The page does not have the script (a chapter just loaded).
        case install
        /// Not for this page (vertical writing).
        case unsupported
    }

    struct Sentence {
        var id: Int
        var text: String
        var before: String?
        var cssSelector: String?
    }

    struct Look: Equatable {
        /// CSS colour of the word's box; nil for no box.
        var word: String?
        /// Opacity of the line's band, in the colour of the text; nil for no band.
        var line: Double?
    }

    /// Where a word is in its sentence, in UTF-16 units (what the page counts in). The word's locator is the
    /// sentence's cut down, so the text before the word is the text before the sentence and then the sentence up
    /// to the word. Nil when that is not so: the word is then Readium's to find.
    static func offsets(sentence: String, before: String?, word: String, beforeWord: String?) -> (from: Int, to: Int)? {
        let lead = (before ?? "").utf16.count, upTo = (beforeWord ?? "").utf16
        let from = upTo.count - lead, length = word.utf16.count
        let whole = sentence.utf16
        guard from >= 0, length > 0, from + length <= whole.count else { return nil }
        let start = whole.index(whole.startIndex, offsetBy: from)
        let end = whole.index(start, offsetBy: length)
        guard whole[start ..< end].elementsEqual(word.utf16), whole[..<start].elementsEqual(upTo.dropFirst(lead)) else { return nil }
        return (from, from + length)
    }

    /// Mark the word at UTF-16 offsets `from ..< to` of the sentence `id`. `stale` or `install` means `give`.
    static func word(sentence id: Int, from: Int, to: Int) -> String {
        "(function(){var p=window.ptSpeech;return p?p.word(\(id),\(from),\(to)):'install';})()"
    }

    /// Hand the page the sentence (and the script, when it said it has none), and mark the word.
    static func give(_ sentence: Sentence, look: Look, from: Int, to: Int, install: Bool) -> String {
        var payload: [String: Any] = ["text": sentence.text]
        if let before = sentence.before { payload["before"] = before }
        if let selector = sentence.cssSelector { payload["selector"] = selector }
        var style: [String: Any] = [:]
        if let word = look.word { style["word"] = word }
        if let line = look.line { style["line"] = line }
        let call = "(function(){var p=window.ptSpeech;if(!p){return 'install';}"
            + "var r=p.sentence(\(sentence.id),\(json(payload)),\(json(style)));"
            + "return r==='ok'?p.word(\(sentence.id),\(from),\(to)):r;})()"
        return install ? source + "\n" + call : call
    }

    /// Take the marks off (the sentence stays known).
    static let clear = "(function(){var p=window.ptSpeech;if(p){p.clear();}return 'ok';})()"
    /// The voice is paused: the marks stay until it goes on, however long that is.
    static let hold = "(function(){var p=window.ptSpeech;if(p){p.hold();}return 'ok';})()"

    private static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        // valid JSON, and these two end a line in older JavaScript. A fixed-layout spread is sent its scripts inside a
        // template literal (`EPUBFixedSpreadView.evaluateScript`), where a book's "${…}" would be run: no bare $ or `
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "$", with: "\\u0024").replacingOccurrences(of: "`", with: "\\u0060")
    }

    /// Installed once per chapter (it does nothing the second time).
    static let source = #"""
    (function () {
      if (window.ptSpeech) { return; }
      var S = { id: null, root: null, at: 0, end: 0, q: null, st: null, last: null, look: {}, box: null, timer: null };
      var cache = null;

      function isSpace(c) {
        return c === 32 || (c >= 9 && c <= 13) || c === 160 || c === 173 || c === 0x200B || c === 0xFEFF
          || c === 0x3000 || c === 0x2028 || c === 0x2029 || c === 0x202F || (c >= 0x2000 && c <= 0x200A);
      }

      // `s` without its spaces, and for each index of `s` how many kept characters come before it
      function strip(s) {
        var map = new Int32Array(s.length + 1), out = [], n = 0;
        for (var i = 0; i < s.length; i++) {
          map[i] = n;
          if (!isSpace(s.charCodeAt(i))) { out.push(s[i]); n++; }
        }
        map[s.length] = n;
        return { text: out.join(''), map: map };
      }

      // its text nodes are still the page's (Bionic Reading swaps them for others of the same length)
      function whole(st) {
        for (var i = 0; i < st.nodes.length; i++) { if (!st.nodes[i].isConnected) { return false; } }
        return true;
      }

      // the characters of `root`, spaces left out, and the text node and offset each came from
      function stream(root) {
        var length = root.textContent.length;
        if (cache && cache.root === root && cache.length === length && whole(cache)) { return cache; }
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
        var nodes = [], parts = [], node, count = 0;
        var which = new Int32Array(length), where = new Int32Array(length);
        while ((node = walker.nextNode())) {
          var parent = node.parentNode, tag = parent && parent.nodeName;
          if (tag === 'SCRIPT' || tag === 'STYLE') { continue; }
          var data = node.data, index = nodes.length, kept = [];
          for (var i = 0; i < data.length; i++) {
            if (isSpace(data.charCodeAt(i))) { continue; }
            if (count >= length) { break; }
            which[count] = index; where[count] = i; count++;
            kept.push(data[i]);
          }
          nodes.push(node);
          parts.push(kept.join(''));
        }
        cache = { root: root, length: length, text: parts.join(''), nodes: nodes, which: which, where: where };
        return cache;
      }

      function vertical() {
        var mode = getComputedStyle(document.body).writingMode || '';
        return mode.indexOf('vertical') === 0;
      }

      function sentence(id, loc, look) {
        S.id = null;
        if (!document.body || vertical()) { return 'unsupported'; }
        var root = null;
        if (loc.selector) { try { root = document.querySelector(loc.selector); } catch (e) { root = null; } }
        if (!root) { root = document.body; }
        var q = strip(loc.text || '');
        if (!q.text) { return 'none'; }
        var st = stream(root);
        var before = strip(loc.before || '').text;
        if (before.length > 24) { before = before.substring(before.length - 24); }
        var first = -1, onward = -1, told = -1, toldOnward = -1, from = 0, p;
        // the sentence said last, given again (the page was rebuilt, the look changed), is where it was
        var key = q.text + '\n' + before;
        var carried = S.root === root ? (S.key === key ? S.at : S.end) : 0;
        while ((p = st.text.indexOf(q.text, from)) >= 0) {
          if (first < 0) { first = p; }
          if (onward < 0 && p >= carried) { onward = p; }
          if (before && p >= before.length && st.text.substring(p - before.length, p) === before) {
            if (told < 0) { told = p; }
            if (p >= carried) { toldOnward = p; }
          }
          from = p + 1;
          if (toldOnward >= 0) { break; }
        }
        // where the text before it says (a refrain: the next such after the sentence said last); else the next one
        // after the sentence said last; else the first
        var at = toldOnward >= 0 ? toldOnward : (told >= 0 ? told : (onward >= 0 ? onward : first));
        if (at < 0) { return 'none'; }
        S.id = id; S.root = root; S.key = key; S.st = st; S.q = q; S.at = at; S.end = at + q.text.length;
        S.last = null;
        setLook(look || {});
        return 'ok';
      }

      function setLook(look) {
        if (S.box && S.look.word === look.word && S.look.line === look.line) { return; }
        S.look = look;
        if (S.box) { S.box.all.remove(); }
        var all = document.createElement('div');
        all.id = 'pt-speech';
        all.dataset.group = 'tts-word';
        all.style.pointerEvents = 'none';
        function make(name) {
          var el = document.createElement('div');
          el.className = name;
          el.dataset.writingMode = 'horizontal-tb';
          el.style.position = 'absolute';
          el.style.pointerEvents = 'none';
          el.style.boxSizing = 'border-box';
          el.style.display = 'none';
          all.appendChild(el);
          return el;
        }
        var line = null, word = null, more = null;
        if (typeof look.line === 'number') {
          line = make('pt-spoken-line');
          line.style.setProperty('background-color', 'currentColor', 'important');
          line.style.opacity = String(look.line);
          line.style.clipPath = 'inset(0 6px round 5px)';
        }
        if (look.word) {
          word = make('pt-spoken-word');
          more = make('pt-spoken-word');
          [word, more].forEach(function (el) {
            el.style.setProperty('background-color', look.word, 'important');
            el.style.borderRadius = '3px';
          });
        }
        S.box = { all: all, line: line, word: word, more: more };
      }

      function rangeOf(a, b) {
        var st = S.st, from = S.at + S.q.map[a], to = S.at + S.q.map[b];
        if (!(to > from) || to > st.text.length) { return null; }
        var range = document.createRange();
        range.setStart(st.nodes[st.which[from]], st.where[from]);
        range.setEnd(st.nodes[st.which[to - 1]], st.where[to - 1] + 1);
        return range;
      }

      // one rectangle per line the range is on
      function lines(range) {
        var rects = range.getClientRects(), out = [];
        for (var i = 0; i < rects.length; i++) {
          var r = rects[i];
          if (r.width < 0.5 || r.height < 0.5) { continue; }
          var l = out.length ? out[out.length - 1] : null;
          var overlap = l ? Math.min(l.bottom, r.bottom) - Math.max(l.top, r.top) : 0;
          if (l && overlap > Math.min(l.bottom - l.top, r.height) / 2 && Math.abs(r.left - l.right) < r.height * 3) {
            l.left = Math.min(l.left, r.left); l.right = Math.max(l.right, r.right);
            l.top = Math.min(l.top, r.top); l.bottom = Math.max(l.bottom, r.bottom);
          } else {
            out.push({ left: r.left, right: r.right, top: r.top, bottom: r.bottom });
          }
        }
        return out;
      }

      function put(el, left, top, width, height) {
        if (!el) { return; }
        el.style.left = left + 'px';
        el.style.top = top + 'px';
        el.style.width = width + 'px';
        el.style.height = height + 'px';
        el.style.display = 'block';
      }

      function hide() {
        if (!S.box) { return; }
        [S.box.line, S.box.word, S.box.more].forEach(function (el) { if (el) { el.style.display = 'none'; } });
        // off the page altogether: whatever asks the page for the voice's mark must not find an empty box
        S.box.all.remove();
      }

      function place(a, b) {
        var range;
        try { range = rangeOf(a, b); } catch (e) { range = null; }
        var found = range ? lines(range) : [];
        if (!found.length || !S.box) { hide(); return 'none'; }
        if (!S.box.all.isConnected) { document.body.appendChild(S.box.all); }
        var scroller = document.scrollingElement || document.documentElement;
        var x = scroller.scrollLeft, y = scroller.scrollTop, r = found[0];
        var columns = parseInt(getComputedStyle(document.documentElement).getPropertyValue('column-count')) || 1;
        var page = window.innerWidth / columns;
        put(S.box.line, Math.floor(r.left / page) * page + x, r.top + y, page, r.bottom - r.top);
        put(S.box.word, r.left + x, r.top + y, r.right - r.left, r.bottom - r.top);
        if (S.box.more) {
          // a word broken over two lines
          var s = found.length > 1 ? found[found.length - 1] : null;
          if (s) { put(S.box.more, s.left + x, s.top + y, s.right - s.left, s.bottom - s.top); }
          else { S.box.more.style.display = 'none'; }
        }
        return (r.right <= 1 || r.left >= window.innerWidth - 1) ? 'off' : 'on';
      }

      function expireLater() {
        if (S.timer) { clearTimeout(S.timer); }
        // a mark nobody moves any more (the voice is in another chapter by now) does not stay for good
        S.timer = setTimeout(function () { S.timer = null; S.last = null; hide(); }, 30000);
      }

      function word(id, a, b) {
        if (S.id !== id) { return 'stale'; }
        // the page was rebuilt under the sentence (the type size, the font): it is found again
        if (!S.root.isConnected || S.root.textContent.length !== S.st.length || !whole(S.st)) { S.id = null; return 'stale'; }
        S.last = [a, b];
        expireLater();
        return place(a, b);
      }

      function again() {
        if (S.id !== null && S.last) { place(S.last[0], S.last[1]); }
      }

      window.ptSpeech = {
        sentence: sentence,
        word: word,
        clear: function () { S.last = null; if (S.timer) { clearTimeout(S.timer); S.timer = null; } hide(); },
        hold: function () { if (S.timer) { clearTimeout(S.timer); S.timer = null; } }
      };

      // the page laid out again (turned to its side, a setting changed): the marks go where the word now is
      window.addEventListener('resize', again);
      if (window.ResizeObserver && document.body) {
        var size = { w: 0, h: 0 };
        new ResizeObserver(function () {
          var body = document.body;
          if (size.w === body.clientWidth && size.h === body.clientHeight) { return; }
          size = { w: body.clientWidth, h: body.clientHeight };
          again();
        }).observe(document.body);
      }
    })();
    """#
}
