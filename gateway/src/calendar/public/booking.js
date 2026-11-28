"use strict";
(function () {
  var dataEl = document.getElementById("booking-data");
  var app = document.getElementById("app");
  if (!dataEl || !app) return;
  var D = JSON.parse(dataEl.textContent);
  var LOCALE = D.locale || "en-US";
  var T = D.text || {};
  function tr(name, params) {
    return (T[name] || name).replace(/\{(\w+)\}/g, function (m, k) {
      return params && k in params ? String(params[k]) : m;
    });
  }
  var PARIS = "Europe/Paris";
  var TZ = (function () {
    try {
      return Intl.DateTimeFormat().resolvedOptions().timeZone || PARIS;
    } catch (e) {
      return PARIS;
    }
  })();
  var state = { month: null, slots: [], byDay: {}, day: null, slot: null, token: null, widget: null, loading: false };

  function h(tag, attrs) {
    var el = document.createElement(tag);
    if (attrs)
      Object.keys(attrs).forEach(function (k) {
        var v = attrs[k];
        if (v === undefined || v === null || v === false) return;
        if (k === "text") el.textContent = v;
        else if (k.slice(0, 2) === "on") el.addEventListener(k.slice(2), v);
        else el.setAttribute(k, v === true ? "" : v);
      });
    for (var i = 2; i < arguments.length; i++) {
      var c = arguments[i];
      if (c === null || c === undefined || c === false) continue;
      (Array.isArray(c) ? c : [c]).forEach(function (x) {
        if (x !== null && x !== undefined && x !== false) el.appendChild(typeof x === "string" ? document.createTextNode(x) : x);
      });
    }
    return el;
  }

  function render(nodes, focusSel) {
    app.replaceChildren.apply(app, nodes);
    var f = focusSel ? app.querySelector(focusSel) : app.querySelector("h2");
    if (f) {
      if (!f.hasAttribute("tabindex") && f.tagName === "H2") f.setAttribute("tabindex", "-1");
      f.focus({ preventScroll: false });
    }
  }

  function fmt(iso, opts, tz) {
    return new Intl.DateTimeFormat(LOCALE, Object.assign({ timeZone: tz || TZ }, opts)).format(new Date(iso));
  }
  var time = function (iso, tz) {
    return fmt(iso, { hour: "2-digit", minute: "2-digit" }, tz);
  };
  var longDate = function (iso, tz) {
    return fmt(iso, { weekday: "long", day: "numeric", month: "long", year: "numeric" }, tz);
  };
  function dayKey(iso, tz) {
    var p = {};
    new Intl.DateTimeFormat("en-CA", { timeZone: tz || TZ, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date(iso)).forEach(function (x) {
      p[x.type] = x.value;
    });
    return p.year + "-" + p.month + "-" + p.day;
  }
  var pad = function (n) {
    return String(n).padStart(2, "0");
  };
  function todayKey() {
    return dayKey(new Date().toISOString());
  }

  function whenLine(start, end) {
    var line = longDate(start) + ", " + time(start) + " – " + time(end);
    if (TZ !== PARIS) line += " (" + tr("inParis", { time: time(start, PARIS) }) + ")";
    return line;
  }

  function locationLabel(loc, meetUrl) {
    if (!loc) return "";
    if (loc.kind === "google_meet") return meetUrl ? tr("meet", { url: meetUrl }) : tr("meetPending");
    if (loc.kind === "phone") return tr("phone", { number: loc.value });
    return loc.value || "";
  }

  async function api(method, url, body) {
    var res = await fetch(url, {
      method: method,
      headers: body ? { "content-type": "application/json" } : {},
      body: body ? JSON.stringify(body) : undefined,
      credentials: "omit",
    });
    var data = null;
    try {
      data = await res.json();
    } catch (e) {}
    return { status: res.status, data: data };
  }

  // ---- calendar ------------------------------------------------------------------------------

  function slotsUrl(from, to) {
    var base = D.mode === "manage" ? "/m/" + encodeURIComponent(D.token) + "/slots" : "/api/public/booking/" + encodeURIComponent(D.slug) + "/slots";
    return base + "?from=" + from + "&to=" + to + "&tz=" + encodeURIComponent(TZ);
  }

  async function loadMonth(y, m, autoAdvance) {
    state.month = { y: y, m: m };
    state.loading = true;
    drawCalendar();
    var last = new Date(Date.UTC(y, m, 0)).getUTCDate();
    var from = y + "-" + pad(m) + "-01";
    var to = y + "-" + pad(m) + "-" + pad(last);
    var r = await api("GET", slotsUrl(from, to));
    state.loading = false;
    state.slots = r.status === 200 && r.data ? r.data.slots : [];
    state.byDay = {};
    state.slots.forEach(function (s) {
      var k = dayKey(s.start);
      (state.byDay[k] = state.byDay[k] || []).push(s);
    });
    var days = Object.keys(state.byDay).sort();
    if (!days.length && autoAdvance > 0) {
      var nm = m === 12 ? 1 : m + 1;
      return loadMonth(m === 12 ? y + 1 : y, nm, autoAdvance - 1);
    }
    if (!state.day || !state.byDay[state.day]) state.day = days[0] || null;
    drawCalendar();
  }

  function shiftMonth(delta) {
    var m = state.month.m + delta;
    var y = state.month.y;
    if (m < 1) (m = 12), y--;
    if (m > 12) (m = 1), y++;
    state.day = null;
    loadMonth(y, m, 0);
  }

  function drawCalendar(focusDay) {
    var y = state.month.y;
    var m = state.month.m;
    var title = new Intl.DateTimeFormat(LOCALE, { month: "long", year: "numeric", timeZone: "UTC" }).format(new Date(Date.UTC(y, m - 1, 1)));
    var now = todayKey().split("-").map(Number);
    var isFirstMonth = y < now[0] || (y === now[0] && m <= now[1]);
    var grid = h("div", { class: "grid", role: "grid", "aria-label": title });
    tr("weekdays").split(",").forEach(function (d) {
      grid.appendChild(h("div", { class: "dow", "aria-hidden": "true", text: d }));
    });
    var first = (new Date(Date.UTC(y, m - 1, 1)).getUTCDay() + 6) % 7;
    for (var i = 0; i < first; i++) grid.appendChild(h("div", { "aria-hidden": "true" }));
    var last = new Date(Date.UTC(y, m, 0)).getUTCDate();
    var today = todayKey();
    for (var d = 1; d <= last; d++) {
      var key = y + "-" + pad(m) + "-" + pad(d);
      var has = !!state.byDay[key];
      var label = new Intl.DateTimeFormat(LOCALE, { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" }).format(new Date(Date.UTC(y, m - 1, d)));
      grid.appendChild(
        h("button", {
          type: "button",
          class: "day" + (has ? " available" : "") + (key === today ? " today" : ""),
          "aria-pressed": has ? String(key === state.day) : null,
          "aria-label": label + ", " + (has ? tr("daySlots", { count: state.byDay[key].length }) : tr("dayNoSlot")),
          "data-day": key,
          disabled: !has,
          text: String(d),
          onclick: (function (k) {
            return function () {
              state.day = k;
              drawCalendar(k);
              var list = app.querySelector(".slots button");
              if (list && window.matchMedia("(max-width: 759px)").matches) list.scrollIntoView({ behavior: "smooth", block: "center" });
            };
          })(key),
        }),
      );
    }
    var cal = h(
      "div",
      { class: "cal" },
      h(
        "div",
        { class: "month-head" },
        h("button", { type: "button", class: "icon-btn", "aria-label": tr("prevMonth"), disabled: isFirstMonth, onclick: function () { shiftMonth(-1); }, text: "‹" }),
        h("h2", { "aria-live": "polite", text: title }),
        h("button", { type: "button", class: "icon-btn", "aria-label": tr("nextMonth"), onclick: function () { shiftMonth(1); }, text: "›" }),
      ),
      grid,
      h("p", { class: "tz", text: tr("timezone", { tz: TZ }) + (TZ !== PARIS ? " · " + tr("timezoneParis") : "") }),
    );
    var side;
    if (state.loading) side = h("p", { class: "muted", role: "status", text: tr("loadingSlots") });
    else if (!state.day) side = h("p", { class: "muted", role: "status", text: tr("noSlotMonth") });
    else
      side = h(
        "div",
        {},
        h("h3", { class: "muted", text: fmt(state.byDay[state.day][0].start, { weekday: "long", day: "numeric", month: "long" }) }),
        h(
          "div",
          { class: "slots" },
          state.byDay[state.day].map(function (s) {
            return h(
              "button",
              { type: "button", class: "slot", "aria-label": whenLine(s.start, s.end), onclick: function () { pickSlot(s); } },
              time(s.start),
              TZ !== PARIS ? h("small", { text: tr("inParis", { time: time(s.start, PARIS) }) }) : null,
            );
          }),
        ),
      );
    var heading =
      D.mode === "manage"
        ? h("div", { class: "actions" }, h("p", { class: "muted", text: tr("pickNew") }), h("button", { type: "button", class: "link", text: tr("back"), onclick: function () { drawManage(); } }))
        : null;
    app.replaceChildren(heading || document.createTextNode(""), h("div", { class: "picker" }, cal, side));
    if (focusDay) {
      var b = app.querySelector('[data-day="' + focusDay + '"]');
      if (b) b.focus();
    }
  }

  // ---- Turnstile -----------------------------------------------------------------------------

  function mountTurnstile(container) {
    state.token = null;
    if (!D.siteKey) return;
    var tries = 0;
    (function attempt() {
      if (window.turnstile && window.turnstile.render) {
        state.widget = window.turnstile.render(container, {
          sitekey: D.siteKey,
          language: D.lang || "auto",
          callback: function (t) { state.token = t; },
          "expired-callback": function () { state.token = null; },
          "error-callback": function () { state.token = null; },
        });
      } else if (tries++ < 50) setTimeout(attempt, 200);
    })();
  }
  function resetTurnstile() {
    state.token = null;
    if (window.turnstile && state.widget !== null) window.turnstile.reset(state.widget);
  }

  // ---- booking form --------------------------------------------------------------------------

  var fieldSeq = 0;
  function field(labelText, input, optional) {
    var id = "f" + ++fieldSeq;
    input.id = id;
    return h("label", { for: id }, h("span", {}, labelText, optional ? h("span", { class: "opt", text: " " + tr("optional") }) : null), input);
  }

  function pickSlot(s) {
    state.slot = s;
    if (D.mode === "manage") return drawRescheduleConfirm();
    var err = h("div", { class: "notice error", role: "alert", hidden: true });
    var qs = (D.questions || []).map(function (q) {
      var name = "q_" + q.id;
      var input;
      if (q.type === "longtext") input = h("textarea", { name: name, maxlength: "2000", required: q.required });
      else if (q.type === "select")
        input = h("select", { name: name, required: q.required }, h("option", { value: "", text: "—" }), q.options.map(function (o) { return h("option", { value: o, text: o }); }));
      else input = h("input", { name: name, type: q.type === "phone" ? "tel" : "text", autocomplete: q.type === "phone" ? "tel" : "off", maxlength: q.type === "phone" ? "40" : "300", required: q.required });
      return field(q.label, input, !q.required);
    });
    var ts = h("div", { class: "ts" });
    var submit = h("button", { type: "submit", class: "primary", text: tr("confirmBooking") });
    var form = h(
      "form",
      { novalidate: true, onsubmit: onSubmit },
      field(tr("name"), h("input", { name: "name", autocomplete: "name", required: true, maxlength: "120" })),
      field(tr("email"), h("input", { name: "email", type: "email", autocomplete: "email", required: true, maxlength: "254", inputmode: "email" })),
      qs,
      field(tr("message"), h("textarea", { name: "notes", maxlength: "2000", placeholder: tr("messagePlaceholder") }), true),
      h("div", { class: "hp", "aria-hidden": "true" }, h("label", {}, tr("honeypot"), h("input", { name: "website", tabindex: "-1", autocomplete: "off" }))),
      ts,
      err,
      h("div", { class: "actions" }, submit, h("button", { type: "button", class: "secondary", text: tr("changeSlot"), onclick: function () { drawCalendar(); } })),
    );
    render([h("h2", { text: tr("yourDetails") }), h("div", { class: "summary" }, h("strong", { text: D.title }), h("span", { text: whenLine(s.start, s.end) })), h("p"), form], 'input[name="name"]');
    mountTurnstile(ts);

    async function onSubmit(ev) {
      ev.preventDefault();
      err.hidden = true;
      if (!form.reportValidity()) return;
      if (D.siteKey && !state.token) return showErr(tr("spamPending"));
      var fd = new FormData(form);
      var answers = {};
      (D.questions || []).forEach(function (q) {
        var v = String(fd.get("q_" + q.id) || "").trim();
        if (v) answers[q.id] = v;
      });
      submit.disabled = true;
      submit.textContent = tr("booking");
      var r = await api("POST", "/api/public/booking/" + encodeURIComponent(D.slug), {
        start: s.start,
        name: String(fd.get("name") || ""),
        email: String(fd.get("email") || ""),
        notes: String(fd.get("notes") || ""),
        answers: answers,
        timezone: TZ,
        website: String(fd.get("website") || ""),
        turnstileToken: state.token || "",
      });
      submit.disabled = false;
      submit.textContent = tr("confirmBooking");
      if (r.status === 201) return drawDone(r.data, String(fd.get("email") || ""));
      resetTurnstile();
      if (r.status === 409) {
        state.day = null;
        await loadMonth(state.month.y, state.month.m, 0);
        var n = h("div", { class: "notice error", role: "alert", text: (r.data && r.data.error) || tr("slotTaken") });
        app.prepend(n);
        return;
      }
      showErr(r.status === 403 ? tr("spamFailedRetry") : (r.data && r.data.error) || tr("errorRetry"));
    }
    function showErr(msg) {
      err.textContent = msg;
      err.hidden = false;
      err.focus && err.setAttribute("tabindex", "-1");
      err.focus();
    }
  }

  function drawDone(out, email) {
    var b = out.booking;
    render([
      h("div", { class: "done-mark", "aria-hidden": "true", text: "✓" }),
      h("h2", { text: tr("confirmed") }),
      h("div", { class: "summary" }, h("strong", { text: b.title }), h("span", { text: whenLine(b.start, b.end) }), h("span", { class: "muted", text: locationLabel(b.location, b.meetUrl) })),
      h("p", { class: "muted", text: email ? tr("invitationSent", { email: email }) : "" }),
      h(
        "div",
        { class: "actions" },
        h("a", { class: "primary", href: out.icsUrl, download: tr("icsFile"), text: tr("addToCalendar") }),
        h("a", { class: "secondary", href: out.manageUrl, text: tr("cancelOrMove") }),
      ),
      h("p", { class: "muted", text: tr("keepLink") }),
    ]);
  }

  // ---- manage --------------------------------------------------------------------------------

  function drawManage(notice) {
    var b = D.booking;
    var active = b.status === "confirmed" || b.status === "pending";
    var nodes = [
      notice || null,
      h("h2", { text: active ? tr("yourAppointment") : b.status === "cancelled" ? tr("cancelledAppointment") : tr("appointment") }),
      h("div", { class: "summary" }, h("strong", { text: b.title }), h("span", { text: whenLine(b.start, b.end) }), active ? h("span", { class: "muted", text: locationLabel(b.location, b.meetUrl) }) : null),
      h("p"),
    ];
    if (active)
      nodes.push(
        h(
          "div",
          { class: "actions" },
          h("button", { type: "button", class: "primary", text: tr("move"), onclick: function () { var t = todayKey().split("-").map(Number); loadMonth(t[0], t[1], 2); } }),
          h("button", { type: "button", class: "danger", text: tr("cancelAppointment"), onclick: drawCancel }),
          h("a", { class: "secondary", href: "/m/" + encodeURIComponent(D.token) + "/event.ics", download: tr("icsFile"), text: tr("icsLink") }),
        ),
      );
    render(nodes.filter(Boolean));
  }

  function drawCancel() {
    var reason = h("textarea", { name: "reason", maxlength: "500" });
    var err = h("div", { class: "notice error", role: "alert", hidden: true });
    var btn = h("button", { type: "submit", class: "danger", text: tr("confirmCancel") });
    render([
      h("h2", { text: tr("cancelQuestion") }),
      h("div", { class: "summary" }, h("strong", { text: D.booking.title }), h("span", { text: whenLine(D.booking.start, D.booking.end) })),
      h("p"),
      h(
        "form",
        {
          onsubmit: async function (ev) {
            ev.preventDefault();
            btn.disabled = true;
            var r = await api("POST", "/m/" + encodeURIComponent(D.token), { action: "cancel", reason: reason.value });
            btn.disabled = false;
            if (r.status === 200) {
              D.booking = r.data.booking;
              return drawManage(h("div", { class: "notice ok", role: "status", text: tr("cancelled") }));
            }
            err.textContent = (r.data && r.data.error) || tr("error");
            err.hidden = false;
          },
        },
        field(tr("reason"), reason, true),
        err,
        h("div", { class: "actions" }, btn, h("button", { type: "button", class: "secondary", text: tr("back"), onclick: function () { drawManage(); } })),
      ),
    ]);
  }

  function drawRescheduleConfirm() {
    var s = state.slot;
    var ts = h("div", { class: "ts" });
    var err = h("div", { class: "notice error", role: "alert", hidden: true });
    var btn = h("button", { type: "submit", class: "primary", text: tr("moveAppointment") });
    render([
      h("h2", { text: tr("confirmNewSlot") }),
      h("div", { class: "summary" }, h("span", { class: "muted", text: tr("before", { when: whenLine(D.booking.start, D.booking.end) }) }), h("strong", { text: tr("after", { when: whenLine(s.start, s.end) }) })),
      h("p"),
      h(
        "form",
        {
          onsubmit: async function (ev) {
            ev.preventDefault();
            if (D.siteKey && !state.token) {
              err.textContent = tr("spamPending");
              err.hidden = false;
              return;
            }
            btn.disabled = true;
            var r = await api("POST", "/m/" + encodeURIComponent(D.token), { action: "reschedule", start: s.start, turnstileToken: state.token || "" });
            btn.disabled = false;
            if (r.status === 200) {
              D.booking = r.data.booking;
              return drawManage(h("div", { class: "notice ok", role: "status", text: tr("moved") }));
            }
            resetTurnstile();
            err.textContent = r.status === 403 ? tr("spamFailed") : (r.data && r.data.error) || tr("error");
            err.hidden = false;
          },
        },
        ts,
        err,
        h("div", { class: "actions" }, btn, h("button", { type: "button", class: "secondary", text: tr("otherSlot"), onclick: function () { drawCalendar(); } })),
      ),
    ]);
    mountTurnstile(ts);
  }

  if (D.mode === "manage") drawManage();
  else {
    var t = todayKey().split("-").map(Number);
    loadMonth(t[0], t[1], 2);
  }
})();
