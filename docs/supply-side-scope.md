# Truffl for carers: supply-side scope

_Status: proposal, September 2026. Owner: Tom. Drafted with Claude._

This document scopes the pivot from "marketplace that needs demand before supply will
sign up" to "the tool a dog carer runs their business on, with Truffl leads on top".
It covers who it is for, the commercial model, the full capability suite, the
architecture decisions that shape it, and a prioritised, ticketed roadmap. Tickets
live in GitHub Issues; the table at the end maps each ticket to its issue.

## 1. The problem

Truffl today is a two-sided marketplace: owners search, vetted carers accept bookings,
Stripe charges on completion. It works end to end, but a marketplace with no demand is
worthless to supply. Nobody will onboard, get vetted and price a profile for a search
page that sends them nothing. The GTM capture flow (TRU-216 to TRU-226) papers over
this with founder-led fulfilment, but it does not give a carer a reason to log in on
a Tuesday.

The insight in the brief: every carer already has a business, and none of them has a
decent place to run it. That is a job they will pay for today, and it puts Truffl in
their pocket before a single lead exists.

## 2. Who it is for

| Segment | What their week looks like | What they need from us | Willing to pay |
|---|---|---|---|
| **Casual independent** (1 to 6 regular dogs, part time) | A few walks a week, mostly friends of friends, arranged over WhatsApp and remembered in Notes or a paper diary. | A calendar that does not forget, a client list with the dog's quirks, a professional-looking way to be booked and paid, the odd lead to keep busy. | Little or nothing. Free tier plus per-lead fee. |
| **Full-time independent** (15 to 40 dogs across Rover, Mad Paws, Pawshake and their own clients) | Juggles three platform apps, a Google Calendar and a wall of WhatsApp threads. Double-books occasionally. Chases invoices at month end. | One calendar with everything in it, one client book, reminders and reports sent for them, invoicing and card payment for own clients, leads to fill gaps. | A$20 to A$40 per month if it saves an hour a week. |
| **Small business** (2 to 10 walkers) | The owner dispatches by group chat, tracks who walked what in a spreadsheet, and pays staff from memory. Clients want to know who is coming. | Assign jobs to walkers, a per-walker run sheet, client records the whole team can see, per-walker earnings, branded client-facing pages. | A$60 to A$150 per month. Currently paying for two or three tools that do not talk to each other. |

The order to win them: **full-time independents first**. They feel the pain most, they
are the best supply for the marketplace (reliable, experienced, already vetted by other
platforms), and they bring 20 to 40 owners each into the client book, which is the seed
of the demand side.

## 3. Positioning and commercial model

**Positioning.** "Run your dog-walking business on Truffl." Truffl is the operating
system for the carer's whole business, not just Truffl bookings. Their clients are
their clients. Truffl earns on the value it adds: the tools, and any customers it
brings them.

**Model (proposal, to confirm with Tom).** This is the hipages shape: a subscription for
the tools plus a fee on work Truffl generates.

| Tier | Price (proposal) | Includes |
|---|---|---|
| Free | A$0 | Client book, schedule, calendar subscribe (ICS), one-off import, quick actions (call, WhatsApp, SMS). Enough to replace the diary. |
| Pro | A$29 / month | Invoicing and Stripe payment links for own clients, walk reports shareable with own clients, automated reminders, Google Calendar two-way sync, public booking page. |
| Business | A$79 / month | Everything in Pro plus team: staff accounts, job assignment, per-walker run sheets and earnings, business branding. |

**Truffl leads.** A booking that originates on the marketplace carries the platform fee
(15% today, set in `charge-booking`). Work the carer brings themselves carries no Truffl
fee, ever. Card payments for own clients go through the carer's existing Stripe Connect
account, so the only cost is Stripe's processing fee.

**Why not a per-lead price like hipages?** Per-lead pricing suits one-off trade jobs.
Dog care is recurring, so a percentage of realised bookings aligns us with the carer:
we earn only when the lead turns into walks. If lead volume becomes meaningful it can
be revisited (see open decisions).

**Open decisions for Tom** (nothing built here depends on them):

1. Price points for Pro and Business, and whether the Free tier caps active clients.
2. Lead fee: keep 15% for the life of the relationship, or taper (for example 15% for
   12 months, then 0%) so a carer never feels penalised for a client staying.
3. Whether Truffl adds a small margin on own-client card payments (for example 0.5%) or
   passes Stripe's fee straight through. Recommendation: pass through, at least until Pro
   has a base.
4. Whether verification (ID, interview, in-person assessment) stays mandatory to use the
   tools. Recommendation: no. Anyone can use the tools; verification is required only to be
   listed on the marketplace and receive leads. That keeps the trust promise to owners
   intact without gating adoption.

## 4. Product principles

- **One place.** Everything the carer does in a day is visible on one screen, whatever
  platform the work came from.
- **Their clients are theirs.** Own-client data is never exposed to other carers or to the
  marketplace. No fee on it. Exportable at any time.
- **Zero-setup value.** The first session must be useful with nothing imported: add a
  client, add a walk, subscribe the calendar, done in five minutes.
- **Meet them where they already are.** WhatsApp, Google Calendar, cash and bank
  transfer are the incumbents. Integrate before replacing.
- **Do not break the marketplace.** Truffl bookings keep their pricing guards, payment
  triggers and meet-and-greet gating untouched. Own-client work lives beside them, not
  inside them.

## 5. The capability suite

Ten epics. Each lists its tickets with a priority: **P0** (foundation, built now),
**P1** (next, makes the product worth paying for and worth listing on), **P2** (scale).

### A. Client book (CRM)

The carer's own list of people and dogs, independent of Truffl accounts. Any owner who
books through the marketplace is added automatically, so the book is complete from day
one. Contact details, address, dogs with breed, age, behaviour and medical notes, vet,
tags, free-text notes, and a history of every job.

- A1 P0. Data model: `clients`, `client_pets`, RLS, auto-link of Truffl owners on their first confirmed booking, backfill.
- A2 P0. `/clients/` page: list, search, add and edit a client and their dogs, notes, archive.
- A3 P0. Quick actions from a client or a job: call, SMS, WhatsApp, email, directions.
- A4 P0. CSV import of clients (Rover and Mad Paws exports, or a template).
- A5 P1. Client detail: job history, lifetime value, last and next job, outstanding balance.
- A6 P1. Import from phone contacts in the native app (Capacitor Contacts).
- A7 P2. Access notes (key safe, alarm, gate) stored separately and masked until tapped; custom fields.

### B. Schedule (unified calendar and run sheet)

One calendar for everything: Truffl bookings, own-client jobs, and imported events. A
job is a unit of work for a client with a start, a duration, a service type, a price
and a status. Recurring jobs materialise from a series the same way Truffl series do.

- B1 P0. Data model: `jobs`, `job_series`, `job_pets`, occurrence generator, nightly roll, `provider_schedule` view uniting jobs and bookings.
- B2 P0. `/schedule/` page: week and day views showing own jobs and Truffl bookings side by side.
- B3 P0. Add one-off and recurring jobs for own clients; mark done, cancelled, paid.
- B4 P1. Drag to reschedule, duplicate, bulk mark done, series editing (this and future).
- B5 P1. Run sheet: today's list ordered by drive time (reuse the OpenRouteService integration), with a map and one-tap navigation.
- B6 P1. Start the GPS walk tracker from an own-client job so non-Truffl clients get the same live map and photos.
- B7 P2. Working hours, capacity and blackout dates; feeds marketplace availability so leads only arrive when there is room.

### C. Bring existing work in (import and calendar sync)

The full-time independent will not retype forty dogs. Getting their existing schedule
in, and getting Truffl's schedule out to the calendar they already look at, is the
adoption gate.

- C1 P0. Calendar subscribe: a private ICS feed URL per carer, works with Google, Apple and Outlook. Edge function `calendar-feed`, token on the profile, rotate on demand.
- C2 P0. One-off `.ics` file import into jobs, with duplicate protection on the event UID.
- C3 P1. Google Calendar two-way sync (OAuth, incremental sync tokens, an edge function plus cron). Jobs created on either side appear on the other.
- C4 P1. Import guides for Rover, Mad Paws and Pawshake (each exposes a calendar or a CSV) plus CSV templates.
- C5 P2. Email forwarding: forward a platform booking confirmation to a Truffl address and a job is created.
- C6 P2. Apple and Outlook two-way via CalDAV.

### D. Client communication

Carers already talk to owners on WhatsApp. First make that faster with templates and
deep links, then automate the routine messages, then bring the channels into Truffl.

- D1 P1. Message templates with merge fields (client, dog, time, price) and one-tap send via WhatsApp, SMS or email from a job or a client: on my way, walk done, reminder for tomorrow, invoice attached.
- D2 P1. Shareable walk report: a public tokenised page for one job showing route, photos, duration and notes, sent to an own client who has no Truffl account.
- D3 P1. Automated reminders: client reminder the evening before, carer's run sheet each morning, overdue invoice nudge. Email first, SMS when D4 lands.
- D4 P2. SMS sending via Twilio with an Australian number and delivery status.
- D5 P2. WhatsApp Business Platform integration (Meta approval, template messages, replies into Truffl).
- D6 P2. Unified inbox: Truffl messages, email and SMS threads per client in one place.

### E. Money (invoicing, payments and Truffl commercials)

- E1 P0. Price per job, mark paid with a method (cash, bank transfer, card, other), owed balance per client.
- E2 P1. Invoices: numbered, with ABN and GST handling, emailed as PDF, per job or per period.
- E3 P1. Stripe payment links and card on file for own clients through the carer's Connect account. No Truffl fee.
- E4 P1. Subscription plans on Stripe Billing: Free, Pro, Business. Entitlement checks in the pages, upgrade prompts at the feature boundary.
- E5 P1. Lead fee: marketplace bookings carry the platform fee, own work does not; the earnings view shows the split so the deal is visible.
- E6 P2. Statements and tax export (CSV per quarter, BAS friendly).
- E7 P2. Prepaid packs and client wallet (for example a ten-walk pack).

### F. Team (multi-walker businesses)

- F1 P2. Business account with staff invites and roles (owner, walker).
- F2 P2. Assign jobs to walkers; a walker sees only their own run sheet.
- F3 P2. Per-walker earnings and pay runs.
- F4 P2. Business branding on client-facing pages and messages.

### G. Public booking page (the acquisition hook)

A shareable page per carer that their own clients use to request work. Requests land
as own-client jobs with no fee, which gives even a casual carer a reason to sign up.

- G1 P1. `/c/<slug>` mini-site: services, prices, service area, request form that creates a client and a pending job.
- G2 P1. Client portal via magic link: upcoming jobs, reports, invoices, pay.
- G3 P2. Reviews from own clients, shown on the mini-site and the marketplace profile.

### H. Positioning, onboarding and growth

- H1 P1. Carer landing page ("Run your dog-walking business on Truffl") and a homepage entry point.
- H2 P1. Registration: tools available immediately after signup; marketplace listing (verification) becomes an optional later step.
- H3 P1. First-run onboarding: import a calendar, add clients, subscribe the calendar; empty states that teach.
- H4 P2. Referral loop: invite an own client to Truffl; a client who joins keeps their carer at no fee.

### I. Reporting

- I1 P1. Earnings dashboard: this month, last month, own versus Truffl, outstanding, walks per week.
- I2 P2. Retention: clients seen in the last 30, 60 and 90 days, lapsed clients to nudge.

### J. Mobile

- J1 P1. New pages verified in the Capacitor shells, deep links into schedule and clients.
- J2 P2. Push notifications for reminders and lead alerts.

## 6. Architecture decisions

These shape everything above. Each was chosen against the current codebase (no-build
static pages, Supabase with RLS, definer RPCs and views, Stripe Connect) and is
recorded so future tickets do not re-open them.

1. **Clients are provider-owned rows, not Truffl accounts.** `clients` belongs to a
   `provider_profiles` row and is only ever readable by that carer. A client may carry a
   `linked_customer_id` to a Truffl owner; a trigger creates and links the client the
   first time a marketplace booking with that owner is confirmed. This makes the client
   book complete on day one without asking owners to do anything.

2. **Jobs beside bookings, not inside them.** Marketplace `bookings` are coupled to
   `customer_profiles`, `pets`, the price guards (TRU-171), the charge-on-completion
   trigger (TRU-146), the meet-and-greet gate and the account-deletion sweep. Forcing
   own-client work through that shape would either weaken those guards or require fake
   owner accounts. So own work is a `jobs` row (with `job_series` for recurrence), and the
   calendar reads a single `provider_schedule` view that unions both. A job never touches
   Stripe charge triggers. If a client later joins Truffl, the link is on the client row
   and history stays intact.

3. **Recurrence mirrors Truffl series.** `job_series` uses the same
   `series_frequency` enum, `days_of_week` (ISO, 1 = Monday) and Sydney-local
   `time_of_day`. `generate_job_occurrences` materialises four weeks ahead, and the
   existing nightly pg_cron slot rolls it forward. One mental model, one bug surface.

4. **Calendar sync starts with ICS.** A per-carer feed URL works with every calendar
   app today, needs no OAuth review and costs one edge function. Google two-way sync is
   P1 because it is the single most requested integration in this segment, but the feed
   ships first.

5. **Messaging starts with deep links.** `wa.me`, `sms:` and `mailto:` with templated
   text give ninety percent of the value with zero API dependencies. The WhatsApp
   Business Platform is expensive to run and slow to approve; it waits for evidence.

6. **Own-client money is recorded first, collected second.** Mark paid (cash, transfer)
   ships in P0. Stripe payment links reuse the carer's Connect account from TRU-143 and
   run as a separate PaymentIntent path, never through `charge-booking`.

7. **Security conventions carry over.** Every new table has RLS keyed on
   `provider_profiles.user_id = (select auth.uid())` (TRU-142 pattern); every definer
   function pins `search_path`; nothing new is granted to `anon`. The account-deletion
   sweep (TRU-228) is extended so a carer's client book is purged when they leave.

8. **No build step, still.** New pages are standalone HTML with inline scripts, matching
   the rest of the site and the CI `node --check` gate. A shared `session.js`-style
   helper for the Supabase calls is worth doing once three or more carer pages exist,
   and is noted in the P1 tickets.

## 7. Roadmap

**Phase 1, "one place for my work" (P0).** Client book, schedule with own jobs and
Truffl bookings together, recurring jobs, calendar subscribe, ICS and CSV import, mark
done and paid. Free tier. This is what makes a full-time independent switch their diary.
_Built in this branch: A1 to A4, B1 to B3, C1, C2, E1._

**Phase 2, "look professional, get paid, get leads" (P1).** Templates and deep-link
messaging, shareable walk reports, reminders, invoices and payment links, Google two-way
sync, the public booking page and client portal, subscription tiers with the lead-fee
split visible, new positioning and onboarding, earnings view, mobile check. This is
where Pro becomes worth A$29 and where the marketplace listing becomes an upsell rather
than the product.

**Phase 3, "teams and scale" (P2).** Business accounts and walker assignment, SMS and
WhatsApp Business, CalDAV, email forwarding import, tax exports, prepaid packs,
retention reporting, push.

Sequencing within Phase 2, in order: H1 and H2 (so the site says what it now is),
D1 and D2 (immediate daily value), E2 and E3 (revenue for the carer), E4 and E5
(revenue for Truffl), C3, G1 and G2, then the rest.

## 8. What is in this branch

- `supabase/migrations/20260911000000_supply_crm_foundation.sql`: clients, client pets,
  jobs, job series and pets, occurrence generation and nightly roll, the
  `provider_schedule` view, calendar feed token, auto-link trigger and backfill for
  Truffl owners, deletion-sweep extension.
- `supabase/functions/calendar-feed/`: the ICS feed.
- `/clients/`: the client book.
- `/schedule/`: the calendar, job editor, ICS import and subscribe link.
- `/dashboard/`: navigation to the new tools and a today summary.

Deployment order matters: apply the migration and deploy the edge function before
merging, because the dashboard links to the new pages as soon as it ships.

### Phase 2 progress

- **H1, H2, H3 (positioning and signup).** `/for-carers/` landing page and a homepage
  section; registration cut to account plus suburb, landing on `/schedule/` with a
  three-step first-run card whose progress is stored on the profile; the dashboard's
  setup checklist reframed as "Get listed on the marketplace" with bio and capabilities
  editors. Decision taken: verification is not required to use the tools.

## 9. Ticket index

Issues are labelled `supply-side` plus `P0`, `P1` or `P2`, and grouped under one epic
issue per section above. P2 items live as checklist lines inside their epic until they
are close enough to split out.

| Epic | Issue | Tickets |
|---|---|---|
| A. Client book | [#136](https://github.com/tomfarmery93/truffl/issues/136) | A1 [#146](https://github.com/tomfarmery93/truffl/issues/146), A2 [#147](https://github.com/tomfarmery93/truffl/issues/147), A3 [#148](https://github.com/tomfarmery93/truffl/issues/148), A4 [#149](https://github.com/tomfarmery93/truffl/issues/149), A5 [#150](https://github.com/tomfarmery93/truffl/issues/150), A6 [#151](https://github.com/tomfarmery93/truffl/issues/151) |
| B. Schedule | [#137](https://github.com/tomfarmery93/truffl/issues/137) | B1 [#152](https://github.com/tomfarmery93/truffl/issues/152), B2 [#153](https://github.com/tomfarmery93/truffl/issues/153), B3 [#154](https://github.com/tomfarmery93/truffl/issues/154), B4 [#155](https://github.com/tomfarmery93/truffl/issues/155), B5 [#156](https://github.com/tomfarmery93/truffl/issues/156), B6 [#157](https://github.com/tomfarmery93/truffl/issues/157) |
| C. Import and calendar sync | [#138](https://github.com/tomfarmery93/truffl/issues/138) | C1 [#158](https://github.com/tomfarmery93/truffl/issues/158), C2 [#159](https://github.com/tomfarmery93/truffl/issues/159), C3 [#160](https://github.com/tomfarmery93/truffl/issues/160), C4 [#161](https://github.com/tomfarmery93/truffl/issues/161) |
| D. Client communication | [#139](https://github.com/tomfarmery93/truffl/issues/139) | D1 [#162](https://github.com/tomfarmery93/truffl/issues/162), D2 [#163](https://github.com/tomfarmery93/truffl/issues/163), D3 [#164](https://github.com/tomfarmery93/truffl/issues/164) |
| E. Money | [#140](https://github.com/tomfarmery93/truffl/issues/140) | E1 [#165](https://github.com/tomfarmery93/truffl/issues/165), E2 [#166](https://github.com/tomfarmery93/truffl/issues/166), E3 [#167](https://github.com/tomfarmery93/truffl/issues/167), E4 [#168](https://github.com/tomfarmery93/truffl/issues/168), E5 [#169](https://github.com/tomfarmery93/truffl/issues/169) |
| F. Team | [#141](https://github.com/tomfarmery93/truffl/issues/141) | all P2, in the epic |
| G. Public booking page | [#142](https://github.com/tomfarmery93/truffl/issues/142) | G1 [#170](https://github.com/tomfarmery93/truffl/issues/170), G2 [#171](https://github.com/tomfarmery93/truffl/issues/171) |
| H. Positioning and onboarding | [#143](https://github.com/tomfarmery93/truffl/issues/143) | H1 [#172](https://github.com/tomfarmery93/truffl/issues/172), H2 [#173](https://github.com/tomfarmery93/truffl/issues/173), H3 [#174](https://github.com/tomfarmery93/truffl/issues/174) |
| I. Reporting | [#144](https://github.com/tomfarmery93/truffl/issues/144) | I1 [#175](https://github.com/tomfarmery93/truffl/issues/175) |
| J. Mobile | [#145](https://github.com/tomfarmery93/truffl/issues/145) | J1 [#176](https://github.com/tomfarmery93/truffl/issues/176) |
