// Validates the cast (`registry/cast/*.json`, ADR 0030): the people whose
// lists every marketing screen shows. Content rules here keep a list real:
// connected, uneven, typed as a person types, and only what Septena ships.

const PERSON_KEYS = { required: ["version", "id", "who", "people", "areas", "projects", "moments"], optional: ["look"] };
const MOMENT_KEYS = { required: ["id", "plot", "project", "order", "tasks", "capture", "anytime", "picked", "open", "file", "dated", "repeating", "attachments", "upcoming", "agent", "discuss", "review", "faded"], optional: ["rolledIn"] };
const TASK_KEYS = { required: ["id", "title", "group"], optional: ["today", "done", "proposal", "unread", "muted", "notes", "due", "repeat", "files"] };
const CONVERSATION = ["title", "notes", "question", "options", "artifact", "bodies", "otherBody", "otherAnswer", "handoff", "acceptance"];
const KEYS = {
  look: { required: ["accent", "texture", "appearance"] },
  area: { required: ["title", "emoji"] },
  project: { required: ["title", "area"], optional: ["progress"] },
  capture: { required: ["title", "group"] },
  file: { required: ["title", "notes", "with"] },
  dated: { required: ["title", "notes", "when", "due"] },
  repeating: { required: ["title", "group", "notes", "repeat", "with"] },
  attachments: { required: ["task", "notes", "files"] },
  day: { required: ["in", "tasks"] },
  ref: { required: ["ref", "due"] },
  agent: { required: [...CONVERSATION, "due"] },
  discuss: { required: [...CONVERSATION, "group", "draftHandoff", "with"] },
  review: { required: ["title", "group", "note", "artifact"] },
};
// What the screens show. One of these losing `ships` on iOS fails the gate.
const FEATURES = ["lists.inbox", "lists.today", "lists.upcoming", "lists.anytime", "lists.review", "lists.faded", "places.areas", "places.projects", "task.when-deadline", "task.repeat", "task.notes", "task.attachments", "task.aging", "ai.discuss", "agents.connector", "agents.stop-pause"];
// Sample-data clichés: the tasks every to-do app's screenshots show.
const CLICHES = /\b(lorem|ipsum|acme|john doe|jane doe|dentist|landlord|launch brief|q[1-4]\b|quarterly|milk|newsletter|deck|circle back|stakeholders?|okrs?|kpis?|sync with|todo|to-do|workout|gym|meditate|inbox zero|overdue)\b/i;
const TITLE_MAX = 46;
const NAV_MAX = 24;
const MIN_FADED = 14;

/** `people`: [{ file, person }]. Throws through `assert` on the first broken rule. */
export function validateCast(people, { tokens, caps, inboxTitle }, assert) {
  const accents = new Set(tokens.fruitAccents.map((item) => item.id));
  const textures = new Set(tokens.textures.map((item) => item.id));
  for (const id of FEATURES) assert(caps.capabilities[id]?.ios === "ships", `cast: every person shows ${id}, which does not ship on ios`);
  const owners = { name: new Map(), look: new Map(), title: new Map() };
  const own = (kind, value, id) => {
    const holder = owners[kind].get(value);
    assert(!holder || holder === id, `cast ${id}: ${kind} "${value}" already belongs to ${holder}`);
    owners[kind].set(value, id);
  };
  for (const { file, person } of people) {
    const at = `cast/${file}`;
    const keys = (value, { required, optional = [] }, path) => {
      assert(value && typeof value === "object" && !Array.isArray(value), `${at}: ${path} must be an object`);
      for (const key of required) assert(key in value, `${at}: ${path} has no ${key}`);
      for (const key of Object.keys(value)) assert(required.includes(key) || optional.includes(key), `${at}: ${path} has an unknown key ${key}`);
    };
    const list = (value, path, min = 1) => assert(Array.isArray(value) && value.length >= min, `${at}: ${path} needs ${min} or more entries`);
    keys(person, PERSON_KEYS, "person");
    assert(person.version === 1, `${at}: version must be 1`);
    assert(file === `${person.id}.json` && /^[a-z]+$/.test(person.id), `${at}: the file is named after the id`);
    list(person.people, "people", 2); list(person.areas, "areas", 3); list(person.projects, "projects", 2); list(person.moments, "moments");
    for (const area of person.areas) { keys(area, KEYS.area, `area ${area.title}`); assert(area.title.length <= NAV_MAX, `${at}: area "${area.title}" is too long for the sidebar`); }
    const areas = new Set(person.areas.map((item) => item.title));
    for (const project of person.projects) {
      keys(project, KEYS.project, `project ${project.title}`);
      assert(areas.has(project.area), `${at}: project "${project.title}" is in an unknown area`);
      assert(project.title.length <= NAV_MAX, `${at}: project "${project.title}" is too long for the sidebar`);
    }
    const places = new Set([...areas, ...person.projects.map((item) => item.title)]);
    assert(places.size === person.areas.length + person.projects.length, `${at}: area and project titles must be unique`);
    {
      keys(person.look, KEYS.look, "look");
      assert(accents.has(person.look.accent), `${at}: unknown accent ${person.look.accent}`);
      assert(textures.has(person.look.texture), `${at}: unknown texture ${person.look.texture}`);
      assert(["light", "dark"].includes(person.look.appearance), `${at}: appearance is light or dark`);
      // Each person's apps wear their own accent and texture (mz, 2026-11-28).
      own("look", `${person.look.accent}/${person.look.texture}`, person.id);
      for (const name of person.people) own("name", name, person.id);
    }

    for (const moment of person.moments) {
      const where = `${at} ${moment.id}`;
      keys(moment, MOMENT_KEYS, `moment ${moment.id}`);
      const { tasks } = moment;
      list(tasks, "tasks", 9);
      const byId = new Map();
      for (const task of tasks) {
        keys(task, TASK_KEYS, `task ${task.id}`);
        assert(!byId.has(task.id), `${where}: duplicate task id ${task.id}`);
        assert(task.group === inboxTitle || places.has(task.group), `${where}: task ${task.id} is in an unknown place "${task.group}"`);
        byId.set(task.id, task);
      }
      const ref = (id, path) => { assert(byId.has(id), `${where}: ${path} names an unknown task ${id}`); return byId.get(id); };
      const onToday = (ids, path, count) => { list(ids, path, count); for (const id of ids) assert(ref(id, path).today, `${where}: ${path} ${id} must be on Today`); };
      const place = (title, path) => assert(places.has(title), `${where}: ${path} is in an unknown place "${title}"`);
      const main = person.projects.find((item) => item.title === moment.project);
      assert(main, `${where}: unknown project ${moment.project}`);
      const own4 = tasks.filter((task) => task.group === moment.project);
      assert(own4.length >= 4 && own4.some((task) => task.done), `${where}: the main project needs four tasks, one done`);
      const inbox = tasks.filter((task) => task.group === inboxTitle);
      assert(inbox.filter((task) => task.proposal).length === 1 && inbox.length >= 2, `${where}: the Inbox needs one proposal and one task of their own`);
      for (const task of tasks) {
        if (task.proposal) assert(task.group === inboxTitle && task.today && !task.unread, `${where}: a proposal waits in the Inbox, unread-free`);
        if (task.today) assert(task.group === inboxTitle || moment.order.includes(task.group), `${where}: Today shows "${task.group}", which order does not list`);
      }
      for (const title of moment.order) place(title, "order");
      assert(tasks.some((task) => task.unread), `${where}: no task has an unread result`);
      keys(moment.capture, KEYS.capture, "capture");
      assert(moment.order.includes(moment.capture.group), `${where}: capture is filed in "${moment.capture.group}", which Today does not show`);
      onToday(moment.anytime, "anytime", 4); onToday(moment.picked, "picked", 2);
      for (const id of moment.picked) assert(moment.anytime.includes(id), `${where}: picked ${id} is not in anytime`);
      assert(moment.open.length === 2 && moment.open.every((id) => { const task = ref(id, "open"); return task.group === moment.project && task.notes; }), `${where}: open names two project tasks with notes`);
      keys(moment.file, KEYS.file, "file"); onToday(moment.file.with, "file.with", 2);
      keys(moment.dated, KEYS.dated, "dated");
      assert(moment.dated.when <= moment.dated.due && moment.upcoming.some((day) => day.in === moment.dated.when), `${where}: dated needs its When day in upcoming, on or before the deadline`);
      keys(moment.repeating, KEYS.repeating, "repeating"); place(moment.repeating.group, "repeating"); onToday(moment.repeating.with, "repeating.with", 2);
      keys(moment.attachments, KEYS.attachments, "attachments");
      assert(ref(moment.attachments.task, "attachments").group === moment.project, `${where}: attachments belong to the main project`);
      list(moment.attachments.files, "attachments.files", 2);
      let last = 0;
      const coming = new Set();
      for (const day of moment.upcoming) {
        keys(day, KEYS.day, "upcoming day");
        assert(Number.isInteger(day.in) && day.in > last && day.in <= 7, `${where}: upcoming days run from 1 to 7 in order`);
        last = day.in;
        for (const entry of day.tasks) {
          let id;
          if (entry === "repeating") id = entry;
          else if (typeof entry === "string") { ref(entry, "upcoming"); id = entry; }
          else if ("ref" in entry) { keys(entry, KEYS.ref, "upcoming ref"); ref(entry.ref, "upcoming"); assert(entry.due >= day.in, `${where}: ${entry.ref} is due before its day`); id = entry.ref; }
          else { keys(entry, TASK_KEYS, `upcoming ${entry.id}`); place(entry.group, `upcoming ${entry.id}`); assert(!byId.has(entry.id), `${where}: upcoming ${entry.id} repeats a task id`); id = entry.id; }
          assert(!coming.has(id), `${where}: upcoming lists ${id} twice`);
          coming.add(id);
        }
      }
      assert(coming.has("repeating"), `${where}: upcoming needs the next repeating task`);
      for (const name of ["agent", "discuss"]) {
        const talk = moment[name];
        keys(talk, KEYS[name], name);
        assert(talk.options.length === 2 && talk.bodies.length === 2 && talk.bodies[0] !== talk.bodies[1], `${where}: ${name} needs two options, each with its own draft`);
        assert(talk.otherBody.includes("{answer}"), `${where}: ${name}.otherBody needs {answer}`);
        assert(!talk.options.includes(talk.otherAnswer), `${where}: ${name}.otherAnswer is a typed answer, not one of the options`);
      }
      place(moment.discuss.group, "discuss"); onToday(moment.discuss.with, "discuss.with", 3);
      list(moment.review, "review", 2);
      for (const item of moment.review) { keys(item, KEYS.review, "review"); place(item.group, "review"); }
      assert(moment.review[0].title === moment.agent.title, `${where}: the first Review row is the agent's task`);
      list(moment.faded, "faded", MIN_FADED);

      const titles = [...tasks.map((task) => task.title), ...moment.upcoming.flatMap((day) => day.tasks.filter((entry) => entry.title).map((entry) => entry.title)), moment.capture.title, moment.file.title, moment.dated.title, moment.repeating.title, moment.agent.title, moment.discuss.title, moment.review[1].title, ...moment.faded];
      for (const title of titles) assert(title.length <= TITLE_MAX, `${where}: "${title}" is longer than ${TITLE_MAX} characters`);
      const strings = [];
      (function collect(value) { if (typeof value === "string") strings.push(value); else if (value && typeof value === "object") Object.values(value).forEach(collect); })(moment);
      for (const text of strings) {
        assert(text.trim() === text && text.length > 0, `${where}: empty or padded text "${text}"`);
        assert(!/[–—]/.test(text), `${where}: em or en dash in "${text}"`);
        assert(!/['"]/.test(text), `${where}: straight quote in "${text}"`);
        const holes = [...text.matchAll(/\{([^}]*)\}/g)].map((match) => match[1]);
        for (const hole of holes) assert(/^weekday([+-]\d+)?$/.test(hole) || hole === "answer", `${where}: unknown placeholder {${hole}}`);
      }
      assert(new Set(titles).size === titles.length, `${where}: a title appears twice: ${titles.find((title, i) => titles.indexOf(title) !== i)}`);
      for (const title of titles) own("title", title, person.id);
      for (const text of strings) {
        assert(!CLICHES.test(text), `${where}: sample-data cliché "${text.match(CLICHES)?.[0]}" in "${text}"`);
        assert(text === moment.plot || !/\b(mon|tues|wednes|thurs|fri|satur|sun)days?\b/i.test(text), `${where}: name a day with {weekday+n} in "${text}"`);
      }
      // Connected: each recurring name shows up on three or more screens' worth of text.
      for (const name of person.people) {
        const hits = strings.filter((text) => new RegExp(`(^|[^\\p{L}])${name}([^\\p{L}]|$)`, "u").test(text)).length;
        assert(hits >= 3, `${where}: ${name} appears ${hits} times; a person in their life appears three times or more`);
      }
      // Uneven: short and long titles together, as a real list has.
      const onTodayTitles = tasks.filter((task) => task.today).map((task) => task.title.split(/\s+/).length);
      assert(Math.min(...onTodayTitles) <= 3 && Math.max(...onTodayTitles) >= 6, `${where}: Today needs a title of three words or fewer and one of six or more`);
    }
  }
}
