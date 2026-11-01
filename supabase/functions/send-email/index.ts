// HERizon | Edge Function: שליחת מייל אישור / תזכורת למועמדת, והתראה למנהלת.
// פריסה:  supabase functions deploy send-email --no-verify-jwt
// סודות:  supabase secrets set RESEND_API_KEY=... FROM_EMAIL="HERizon <hello@your-domain.com>" SITE_URL=https://your-site.netlify.app
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const RESEND = Deno.env.get("RESEND_API_KEY");
const FROM = Deno.env.get("FROM_EMAIL") ?? "HERizon <onboarding@resend.dev>";
const SITE = (Deno.env.get("SITE_URL") ?? "").replace(/\/$/, "");
const TZ = "Asia/Jerusalem";

const fmtDate = (iso: string) =>
  new Intl.DateTimeFormat("he-IL", { timeZone: TZ, weekday: "long", day: "numeric", month: "long", year: "numeric" }).format(new Date(iso));
const fmtTime = (iso: string) =>
  new Intl.DateTimeFormat("he-IL", { timeZone: TZ, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date(iso));
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

function gcal(iso: string, meet: string) {
  const st = (ms: number) => new Date(ms).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const s = Date.parse(iso);
  return "https://calendar.google.com/calendar/render?action=TEMPLATE&text=" + encodeURIComponent("HERizon | שיחת היכרות") +
    "&dates=" + st(s) + "/" + st(s + 600000) +
    (meet ? "&location=" + encodeURIComponent(meet) : "");
}

function layout(title: string, body: string) {
  return `<!doctype html><html lang="he" dir="rtl"><body style="margin:0;background:#FAF6EF;font-family:Arial,Helvetica,sans-serif;color:#2B1745">
  <div style="max-width:560px;margin:0 auto;padding:24px 16px">
    <div style="background:#34165A;color:#FBF7F0;border-radius:18px 18px 0 0;padding:26px 24px;text-align:right">
      <div style="font-family:Georgia,serif;font-size:22px;letter-spacing:.02em;direction:ltr;text-align:right"><b>HER</b>izon</div>
      <div style="font-family:Georgia,serif;font-style:italic;color:#CDBDEB;direction:ltr;text-align:right;font-size:14px">Connect. Grow. Belong.</div>
    </div>
    <div style="background:#fff;border:1px solid #E7DFF1;border-top:0;border-radius:0 0 18px 18px;padding:26px 24px;line-height:1.7;font-size:16px">
      <h2 style="margin:0 0 12px;color:#4A2377;font-size:22px">${title}</h2>${body}
      <p style="margin-top:22px">נתראה בקרוב,<br/>צוות HERizon</p>
    </div>
    <p style="text-align:center;color:#6C5D80;font-size:12px">HERizon · קהילת DDos Women</p>
  </div></body></html>`;
}

function whenBox(iso: string, meet: string) {
  return `<div style="background:#EEE7F8;border-radius:14px;padding:14px 18px;margin:14px 0">
    <div style="font-size:19px;color:#4A2377"><b>${fmtDate(iso)}</b></div>
    <div style="font-size:19px;direction:ltr;text-align:right"><b>${fmtTime(iso)}</b> <span style="font-size:14px;color:#6C5D80">(שעון ישראל, כ-10 דקות)</span></div>
    ${meet ? `<div style="margin-top:8px">קישור לשיחה: <a href="${esc(meet)}" style="color:#4A2377">${esc(meet)}</a></div>` : ""}
  </div>`;
}

// זימון יומן אמיתי (iCalendar METHOD:REQUEST). אותו UID בכל שליחה, ו-SEQUENCE עולה, כך ששינוי מועד מעדכן את האירוע הקיים.
const fold = (l: string) => l.replace(/(.{35})(?=.)/g, "$1\r\n ");
const esc2 = (t: string) => t.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\n/g, "\\n");
function buildInvite(b: { id: string; starts_at: string; full_name: string; email: string }, meet: string) {
  const st = (ms: number) => new Date(ms).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const s0 = Date.parse(b.starts_at);
  const organizer = (FROM.match(/<([^>]+)>/)?.[1] ?? FROM).trim();
  const desc = "שיחת היכרות קצרה (10 דקות) לקראת תוכנית HERizon." + (meet ? "\nקישור לשיחה: " + meet : "");
  const lines = [
    "BEGIN:VCALENDAR", "PRODID:-//HERizon//he", "VERSION:2.0", "CALSCALE:GREGORIAN", "METHOD:REQUEST",
    "BEGIN:VEVENT", `UID:booking-${b.id}@herizon`, `DTSTAMP:${st(Date.now())}`,
    `SEQUENCE:${Math.floor(Date.now() / 60000)}`,
    `DTSTART:${st(s0)}`, `DTEND:${st(s0 + 600000)}`,
    "SUMMARY:" + esc2("HERizon | שיחת היכרות"), "DESCRIPTION:" + esc2(desc),
    ...(meet ? ["LOCATION:" + esc2(meet), "URL:" + meet] : []),
    `ORGANIZER;CN=HERizon:mailto:${organizer}`,
    `ATTENDEE;CN="${b.full_name.replace(/["\r\n]/g, "")}";ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:${b.email}`,
    "STATUS:CONFIRMED", "TRANSP:OPAQUE",
    "BEGIN:VALARM", "TRIGGER:-PT15M", "ACTION:DISPLAY", "DESCRIPTION:HERizon", "END:VALARM",
    "END:VEVENT", "END:VCALENDAR",
  ];
  const text = lines.map(fold).join("\r\n") + "\r\n";
  const bytes = new TextEncoder().encode(text);
  let bin = ""; bytes.forEach((x) => (bin += String.fromCharCode(x)));
  return { filename: "herizon-invite.ics", content: btoa(bin), content_type: "text/calendar; charset=UTF-8; method=REQUEST" };
}

async function send(to: string[], subject: string, html: string, attachments?: unknown[]) {
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to, subject, html, ...(attachments ? { attachments } : {}) }),
  });
  if (!r.ok) throw new Error("resend " + r.status + " " + (await r.text()));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    if (!RESEND) return json({ ok: false, reason: "email_not_configured" });
    const { action, token, booking_id } = await req.json();
    const db = createClient(URL_, SERVICE);
    const { data: settings } = await db.from("settings").select("*");
    const st: Record<string, string> = {};
    (settings ?? []).forEach((r: { key: string; value: string }) => (st[r.key] = r.value));
    const meet = st.meet_link ?? "";

    if (action === "confirmation") {
      // המועמדת מזהה את עצמה רק בעזרת הטוקן האישי של ההזמנה. המייל תמיד נשלח לכתובת שנשמרה בהזמנה.
      if (typeof token !== "string") return json({ ok: false, reason: "bad_request" }, 400);
      const { data: b } = await db.from("bookings").select("*").eq("token", token).maybeSingle();
      if (!b || b.status !== "scheduled") return json({ ok: false, reason: "not_found" });
      if (b.confirmation_sent_at) return json({ ok: true, already: true }); // מונע שליחה חוזרת/ספאם
      const manage = SITE ? `${SITE}/#manage-${b.token}` : "";
      await send([b.email], "HERizon | השיחה שלנו נקבעה 💜", layout("השיחה שלנו נקבעה! 💜",
        `<p>היי ${esc(b.full_name)},</p><p>מחכות להכיר אותך. אלה פרטי שיחת ההיכרות:</p>${whenBox(b.starts_at, meet)}
         <p><a href="${gcal(b.starts_at, meet)}" style="color:#4A2377">הוספה ליומן Google</a></p>
         <p style="font-size:14px;color:#6C5D80">מצורף זימון יומן (קובץ ‎.ics‎). אפשר ללחוץ עליו כדי להוסיף את השיחה ל-Google Calendar או ל-Outlook.</p>
         ${manage ? `<p style="font-size:14px;color:#6C5D80">צריך לשנות או לבטל? <a href="${manage}" style="color:#4A2377">לינק אישי לניהול השיחה</a></p>` : ""}`),
        [buildInvite(b, meet)]);
      await db.from("bookings").update({ confirmation_sent_at: new Date().toISOString() }).eq("id", b.id);
      // התראה למנהלות (כשל כאן לא מפיל את האישור למועמדת)
      if (st.admin_notify_email) {
        try {
          await send([st.admin_notify_email], `ראיון חדש: ${b.full_name} · ${fmtDate(b.starts_at)} ${fmtTime(b.starts_at)}`,
            layout("נקבעה שיחת היכרות חדשה", `${whenBox(b.starts_at, "")}<p><b>${esc(b.full_name)}</b><br/>${esc(b.email)}<br/>${esc(b.phone)}</p>`));
        } catch (e) { console.error("admin notify failed", e); }
      }
      return json({ ok: true });
    }

    if (action === "reminder") {
      // רק מנהלת מחוברת
      const authHeader = req.headers.get("Authorization") ?? "";
      const asUser = createClient(URL_, ANON, { global: { headers: { Authorization: authHeader } } });
      const { data: isAdmin } = await asUser.rpc("is_admin");
      if (!isAdmin) return json({ ok: false, reason: "forbidden" }, 403);
      const { data: b } = await db.from("bookings").select("*").eq("id", booking_id).maybeSingle();
      if (!b || b.status !== "scheduled") return json({ ok: false, reason: "not_found" });
      const manage = SITE ? `${SITE}/#manage-${b.token}` : "";
      await send([b.email], "HERizon | תזכורת לשיחת ההיכרות שלנו", layout("תזכורת לשיחת ההיכרות",
        `<p>היי ${esc(b.full_name)},</p><p>רצינו להזכיר שיחת היכרות קצרה שקבענו:</p>${whenBox(b.starts_at, meet)}
         ${manage ? `<p style="font-size:14px;color:#6C5D80">לא מסתדר? <a href="${manage}" style="color:#4A2377">אפשר לשנות או לבטל כאן</a></p>` : ""}`),
        [buildInvite(b, meet)]);
      await db.from("bookings").update({ reminder_sent_at: new Date().toISOString() }).eq("id", b.id);
      return json({ ok: true });
    }

    if (action === "invite") {
      // מנהלת מחוברת שולחת (או שולחת מחדש) זימון יומן לשעה שנבחרה
      const authHeader = req.headers.get("Authorization") ?? "";
      const asUser = createClient(URL_, ANON, { global: { headers: { Authorization: authHeader } } });
      const { data: isAdmin } = await asUser.rpc("is_admin");
      if (!isAdmin) return json({ ok: false, reason: "forbidden" }, 403);
      const { data: b } = await db.from("bookings").select("*").eq("id", booking_id).maybeSingle();
      if (!b || b.status !== "scheduled") return json({ ok: false, reason: "not_found" });
      const manage = SITE ? `${SITE}/#manage-${b.token}` : "";
      await send([b.email], "HERizon | זימון לשיחת היכרות", layout("זימון לשיחת היכרות",
        `<p>היי ${esc(b.full_name)},</p><p>מצורף זימון ליומן לשיחת ההיכרות שלנו:</p>${whenBox(b.starts_at, meet)}
         <p><a href="${gcal(b.starts_at, meet)}" style="color:#4A2377">הוספה ליומן Google</a></p>
         ${manage ? `<p style="font-size:14px;color:#6C5D80">לשינוי או ביטול: <a href="${manage}" style="color:#4A2377">לינק אישי</a></p>` : ""}`),
        [buildInvite(b, meet)]);
      await db.from("bookings").update({ confirmation_sent_at: new Date().toISOString() }).eq("id", b.id);
      return json({ ok: true });
    }

    return json({ ok: false, reason: "unknown_action" }, 400);
  } catch (e) {
    console.error(e);
    return json({ ok: false, reason: "failed" });
  }
});
