# LegalTribe analysis and LawRelay product brief

## What LegalTribe solves

LegalTribe is a Belgian, lawyer-only marketplace built around two recurring coordination problems:

1. finding another lawyer to attend a court hearing;
2. outsourcing a bounded legal assignment to a qualified colleague.

The public product story is deliberately narrow. A lawyer posts the court, date, time, practice area, or assignment details. Relevant colleagues can respond with their availability, experience, and rate. The posting lawyer compares candidates and selects one. LegalTribe's public material emphasizes less telephone and email coordination, requester control, transparent rates, and the trust of a lawyer-only network.

Publicly described product mechanics include assignment notifications, candidate review, bid rates, court and practice-area preferences, a boost action, calendar views, profiles, and colleague invitations. Detailed case communication, document transfer, and invoicing were described as taking place outside the platform, which keeps the original marketplace focused on discovery and matching.

## Live authenticated product audit — 28 October 2026

The live application at `app.legaltribe.eu` is still operating. A read-only review of an authenticated account confirmed a broader product than the archived marketing site exposed:

- one account switches between **requester** (post work) and **executor** (find work) roles;
- requester work is separated into open, active, performed, and closed states;
- executor work is separated into suggestions, applications, active matters, and closed matters, with list and calendar views;
- professional profiles contain practice areas, preferred courts, bar seniority, and education;
- matching suggestions are based on that professional profile;
- court-cover posts capture court, replacement subtype, hearing time, candidacy deadline, description, and manual or first-candidate assignment;
- legal-task posts capture task subtype, execution language, scope indication, candidacy deadline, dossier-delivery date, execution deadline, and one or more practice areas;
- candidates choose an hourly or fixed proposed rate;
- organisation accounts have owner/administrator/member roles and email invitations;
- a dedicated “action required” queue surfaces matters needing attention.

The review also exposed patterns LawRelay should deliberately improve rather than copy. LegalTribe shows requester identity and matter descriptions before acceptance, its public Terms and Privacy routes still contain placeholder text, and the permanent cookie dialog dominates authenticated pages. LawRelay therefore keeps closed matters participant-only, exchanges contact details only after acceptance, requires an explicit no-confidential-data confirmation, and treats complete legal/operator disclosure as a release gate.

### Public registration follow-up

LegalTribe's live `/register` page asks for surname, first name, email, password/confirmation, an “I am a lawyer” checkbox, and terms/privacy acceptance. No official-directory field or invitation code is visible. This establishes its public registration interface, not its unobservable backend verification rules.

LawRelay's operator selected open registration for lawyers listed on `advocaat.be`, without invitation or cohort limits. LawRelay checks the official profile and control of its published professional email before granting marketplace access; free beta access follows verification automatically.

## Sources reviewed

- [LegalTribe public website](https://www.legaltribe.eu/)
- [LegalTribe LinkedIn company page](https://www.linkedin.com/company/legaltribe)
- [Crunchbase company profile](https://www.crunchbase.com/organization/legaltribe)
- [Chapeau Magazine company profile, 24 October 2025](https://www.chapeaumagazine.com/ondernemen-economie/twee-broers-grensoverschrijdend-ondernemen-limburg/)
- Internet Archive snapshots from April 2025.
- Read-only public and authenticated review of [app.legaltribe.eu](https://app.legaltribe.eu/) on 28 October 2026. No records were created or changed during the audit.

## Product decisions for LawRelay

LawRelay keeps the strong marketplace loop while giving it its own brand and interface. The English name is neutral across Belgium's Dutch- and French-speaking markets, while “relay” describes the core product action: passing a hearing or bounded legal assignment to the right colleague without losing control. AWS Route 53 Domains reported `lawrelay.be` as available on 28 October 2026. A basic web collision check found no obvious active legal-tech product using the exact name; formal Benelux/EU trademark clearance is still required before launch.

- two first-class assignment types: court replacement and legal work;
- a browseable, filterable assignment board;
- structured assignment posting with court, time, location, expertise, language, and fee;
- proposals with a proposed rate, rate type, and short motivation;
- a compact dashboard for postings and responses;
- complete NL/FR/DE/EN interface foundations using neutral English URL slugs;
- no invented customer claims, testimonials, or adoption metrics;
- seeded sample content is visibly labelled as demo content;
- verified accounts, firm-scoped authorization, audited state transitions, and notifications;
- no file transfer or private matter messaging in the initial release; those require a separate threat model.

LawRelay is free. The [former subscription idea](archive/pricing.md) is archived; links to the operator's other products may help support hosting.

## Next product increments

1. validate structured court/legal briefs and matching quality with a founding cohort;
2. populate and maintain a canonical Belgian court directory;
3. approve and automate privacy-retention/export/deletion operations after policy review;
4. add team invitations and multi-office controls only after the single-firm pilot works;
5. add calendar sync after the core assignment lifecycle is stable;
6. complete the remaining independent legal, accessibility, and security reviews.
