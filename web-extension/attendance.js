const DEFAULT_MODEL = "openai/gpt-4o-mini";
const $ = (id) => document.getElementById(id);
let session = null;
let apiKey = "";
let model = DEFAULT_MODEL;

function rosterNames(value) {
  const lines = value.replace(/^\uFEFF/, "").split(/\r?\n/);
  const names = [];
  const seen = new Set();
  for (const line of lines) {
    const cells = line.split(/[,;\t]/).map((cell) => cell.trim().replace(/^"|"$/g, ""));
    const name = cells.find((cell) => cell && !/^(name|student|student name|full name)$/i.test(cell));
    if (!name) continue;
    const key = normalize(name);
    if (!seen.has(key)) { seen.add(key); names.push(name); }
  }
  return names;
}

function normalize(value) {
  return String(value || "").normalize("NFKD")
    .replace(/[\u064B-\u065F\u0670]/g, "")
    .replace(/[إأآٱ]/g, "ا").replace(/ى/g, "ي").replace(/ة/g, "ه")
    .replace(/[^\p{L}\p{N}]+/gu, " ").trim().toLocaleLowerCase();
}

function tokens(value) { return normalize(value).split(" ").filter((part) => part.length > 1); }
function bigrams(value) { const s = normalize(value).replace(/\s/g, ""); return new Set([...s].slice(0,-1).map((c,i)=>c+s[i+1])); }
function similarity(a, b) {
  const na = normalize(a), nb = normalize(b);
  if (!na || !nb) return 0;
  if (na === nb) return 1;
  const ta = tokens(a), tb = tokens(b);
  const overlap = ta.filter((x) => tb.includes(x)).length;
  const tokenScore = overlap / Math.max(ta.length, tb.length, 1);
  const ba = bigrams(a), bb = bigrams(b);
  const shared = [...ba].filter((x) => bb.has(x)).length;
  const dice = ba.size + bb.size ? (2 * shared) / (ba.size + bb.size) : 0;
  return Math.max(tokenScore, dice);
}

function localMatches(roster, observed) {
  const candidates = [];
  roster.forEach((student, si) => observed.forEach((zoom, zi) => candidates.push({ si, zi, score: similarity(student, zoom.name) })));
  candidates.sort((a, b) => b.score - a.score);
  const usedStudents = new Set(), usedObserved = new Set(), matches = {};
  for (const candidate of candidates) {
    if (candidate.score < 0.72 || usedStudents.has(candidate.si) || usedObserved.has(candidate.zi)) continue;
    const competing = candidates.some((other) => other !== candidate && other.zi === candidate.zi && !usedStudents.has(other.si) && Math.abs(other.score - candidate.score) < 0.08);
    matches[candidate.si] = { observedKey: observed[candidate.zi].key, confidence: candidate.score, source: "local", review: competing || candidate.score < 0.82 };
    usedStudents.add(candidate.si); usedObserved.add(candidate.zi);
  }
  return matches;
}

function currentObserved() {
  return Object.entries(session?.observed || {})
    .map(([key, entry]) => ({ ...entry, key }))
    .sort((a,b)=>a.name.localeCompare(b.name));
}

function stableStoredMatches(stored, observed) {
  const validKeys = new Set(observed.map((entry) => entry.key));
  const result = {};
  for (const [studentIndex, match] of Object.entries(stored || {})) {
    // Older matches used a movable array index. Ignore them rather than ever
    // showing one student under a different Zoom identity after the list grows.
    if (!match?.observedKey || !validKeys.has(match.observedKey)) continue;
    result[studentIndex] = match;
  }
  return result;
}

function calculate() {
  if (!session) return {};
  const observed = currentObserved();
  const sources = [
    stableStoredMatches(session.manualMatches, observed),
    stableStoredMatches(session.aiMatches, observed),
    localMatches(session.roster || [], observed)
  ];
  const result = {}, usedNames = new Set();
  for (const source of sources) {
    for (const [studentIndex, match] of Object.entries(source)) {
      if (result[studentIndex] || usedNames.has(match.observedKey)) continue;
      result[studentIndex] = match;
      usedNames.add(match.observedKey);
    }
  }
  return result;
}

async function persist() { await chrome.storage.local.set({ attendanceSession: session }); render(); }

function render() {
  const roster = session?.roster || [];
  const observed = currentObserved();
  const matches = calculate();
  const usedObservedKeys = new Set(Object.values(matches).map((match) => match.observedKey));
  const unmatchedObserved = observed.filter((entry) => !usedObservedKeys.has(entry.key));
  $("sessionName").value = session?.name || $("sessionName").value;
  $("roster").value = roster.join("\n");
  $("rosterCount").textContent = roster.length;
  $("observedCount").textContent = observed.length;
  $("livePill").dataset.live = String(Boolean(session?.active));
  $("liveText").textContent = session?.active ? "Recording" : "Not recording";
  $("stopSession").disabled = !session?.active;
  $("captureNow").disabled = !session?.active;
  const present = Object.values(matches).filter((m) => !m.review).length;
  const review = Object.values(matches).filter((m) => m.review).length;
  $("presentCount").textContent = present;
  $("reviewCount").textContent = review;
  $("absentCount").textContent = Math.max(0, roster.length - present - review);
  $("captureMeta").textContent = session?.lastCapturedAt ? `${session.snapshots || 0} snapshots · Last ${new Date(session.lastCapturedAt).toLocaleString()}` : "No snapshots yet.";
  $("observedNames").innerHTML = observed.map((entry) => `<span class="chip ${usedObservedKeys.has(entry.key) ? "matched" : "unmatched"}">${escapeHTML(entry.name)} <small>×${entry.sightings || 1}</small></span>`).join("");
  $("unmatchedObservedCount").textContent = unmatchedObserved.length;
  $("unmatchedObservedNames").innerHTML = unmatchedObserved.length
    ? unmatchedObserved.map((entry) => `<span class="chip unmatched">${escapeHTML(entry.name)}</span>`).join("")
    : '<span class="status-line">Every captured name is matched.</span>';
  const body = $("results"); body.textContent = "";
  $("emptyState").hidden = roster.length > 0;
  roster.forEach((student, index) => {
    const match = matches[index];
    const row = document.createElement("tr");
    const status = match ? (match.review ? "Needs review" : "Present") : "Absent";
    const statusClass = match ? (match.review ? "review" : "present") : "absent";
    row.innerHTML = `<td>${escapeHTML(student)}</td><td><span class="badge ${statusClass}">${status}</span></td>`;
    const matchCell = document.createElement("td");
    const select = document.createElement("select");
    select.innerHTML = `<option value="">No match</option>` + observed.map((entry) => `<option value="${escapeHTML(entry.key)}" ${match?.observedKey === entry.key ? "selected" : ""}>${escapeHTML(entry.name)}</option>`).join("");
    select.addEventListener("change", async () => {
      session.manualMatches ||= {};
      if (select.value === "") delete session.manualMatches[index];
      else {
        for (const [otherIndex, other] of Object.entries(session.manualMatches)) {
          if (otherIndex !== String(index) && other.observedKey === select.value) delete session.manualMatches[otherIndex];
        }
        session.manualMatches[index] = { observedKey: select.value, confidence: 1, source: "manual", review: false };
      }
      await persist();
    });
    matchCell.append(select); row.append(matchCell);
    const confidence = document.createElement("td");
    confidence.textContent = match ? `${Math.round(match.confidence * 100)}% · ${match.source}` : "—";
    row.append(confidence); body.append(row);
  });
}

function escapeHTML(value) { const span = document.createElement("span"); span.textContent = value; return span.innerHTML; }

async function captureNow() {
  const tabs = await chrome.tabs.query({ url: ["https://*.zoom.us/wc/*", "https://*.zoom.us/j/*", "https://*.zoom.us/s/*", "https://*.zoom.us/w/*"] });
  const batches = [];
  for (const tab of tabs) {
    if (!tab.id) continue;
    try { const reply = await chrome.tabs.sendMessage(tab.id, { type: "captureAttendance" }); if (reply?.names?.length) batches.push(...reply.names); } catch { /* frame or stale tab */ }
  }
  if (!batches.length) { $("aiStatus").textContent = "No names found. Open Zoom's Participants panel and try again."; return; }
  const now = new Date().toISOString(); session.observed ||= {};
  for (const name of batches) {
    const key = name.toLocaleLowerCase(), prior = session.observed[key];
    session.observed[key] = { name: prior?.name || name, firstSeenAt: prior?.firstSeenAt || now, lastSeenAt: now, sightings: (prior?.sightings || 0) + 1 };
  }
  session.snapshots = (session.snapshots || 0) + 1; session.lastCapturedAt = now;
  await persist();
}

async function runAI() {
  if (!apiKey) { $("aiStatus").textContent = "Add and save an OpenRouter API key first."; return; }
  const observed = currentObserved(), matches = calculate();
  const used = new Set(Object.values(matches).map((m) => m.observedKey));
  const students = (session?.roster || []).map((name,index)=>({id:`s${index}`,name,index})).filter((x)=>!matches[x.index]);
  const names = observed.map((entry,index)=>({id:`z${index}`,name:entry.name,key:entry.key})).filter((x)=>!used.has(x.key));
  if (!students.length || !names.length) { $("aiStatus").textContent = "There are no unresolved student/name pairs to send."; return; }
  $("runAI").disabled = true; $("aiStatus").textContent = `Matching ${students.length} students against ${names.length} Zoom names…`;
  const prompt = `Match official student names to Zoom display names. Handle Arabic/English transliteration, spelling differences, missing middle names, reordered names, and nicknames. Never guess when multiple students compete. Use only the IDs supplied. Reply with JSON only: {"matches":[{"student_id":"s0","observed_name_id":"z0","confidence":0.95,"needs_review":false}]}.\nStudents:\n${JSON.stringify(students.map(({id,name})=>({id,name})))}\nZoom names:\n${JSON.stringify(names.map(({id,name})=>({id,name})))}`;
  try {
    const response = await fetch("https://openrouter.ai/api/v1/chat/completions", { method:"POST", headers:{"Content-Type":"application/json",Authorization:`Bearer ${apiKey}`,"X-Title":"Zoom Auto Admit Attendance"}, body:JSON.stringify({model:model || DEFAULT_MODEL,temperature:0,response_format:{type:"json_object"},messages:[{role:"system",content:"Return valid JSON only."},{role:"user",content:prompt}]}) });
    if (!response.ok) throw new Error(`OpenRouter returned HTTP ${response.status}`);
    const payload = await response.json();
    const raw = payload?.choices?.[0]?.message?.content || "{}";
    const parsed = JSON.parse(raw.replace(/^```(?:json)?\s*|\s*```$/g, ""));
    session.aiMatches ||= {}; let accepted = 0;
    const claimedStudents = new Set(), claimedNames = new Set();
    for (const item of parsed.matches || []) {
      const student = students.find((x)=>x.id===item.student_id), name = names.find((x)=>x.id===item.observed_name_id);
      const confidence = Number(item.confidence);
      if (!student || !name || claimedStudents.has(student.id) || claimedNames.has(name.id) || !Number.isFinite(confidence) || confidence < .65) continue;
      session.aiMatches[student.index] = { observedKey:name.key, confidence:Math.min(1,Math.max(0,confidence)), source:"AI", review:Boolean(item.needs_review)||confidence<.85 }; accepted++;
      claimedStudents.add(student.id); claimedNames.add(name.id);
    }
    await persist(); $("aiStatus").textContent = `AI proposed ${accepted} match${accepted===1?"":"es"}. Review them before export.`;
  } catch (error) { $("aiStatus").textContent = `AI matching failed: ${error.message}`; }
  finally { $("runAI").disabled = false; }
}

function csvEscape(value) { const text=String(value??""); return /[",\n]/.test(text)?`"${text.replace(/"/g,'""')}"`:text; }
function exportCSV() {
  const observed=currentObserved(), matches=calculate();
  const observedByKey=new Map(observed.map((entry)=>[entry.key,entry]));
  const rows=[["Official Name","Status","Zoom Display Name","Confidence","Source","Session","Started At","Ended At"]];
  (session?.roster||[]).forEach((student,index)=>{const match=matches[index];rows.push([student,match?(match.review?"Needs Review":"Present"):"Absent",match?observedByKey.get(match.observedKey)?.name||"":"",match?Math.round(match.confidence*100)+"%":"",match?.source||"",session?.name||"",session?.startedAt||"",session?.endedAt||""]);});
  const blob=new Blob(["\uFEFF"+rows.map((row)=>row.map(csvEscape).join(",")).join("\r\n")],{type:"text/csv;charset=utf-8"});
  const url=URL.createObjectURL(blob); const a=document.createElement("a");a.href=url;a.download=`zoom-attendance-${new Date().toISOString().slice(0,10)}.csv`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
}

$("startSession").onclick=async()=>{const roster=rosterNames($("roster").value);session={name:$("sessionName").value.trim()||`Zoom meeting ${new Date().toLocaleString()}`,active:true,startedAt:new Date().toISOString(),endedAt:null,roster,observed:{},snapshots:0,aiMatches:{},manualMatches:{}};await chrome.storage.local.set({attendanceEnabled:true});await persist();await captureNow();};
$("stopSession").onclick=async()=>{if(!session)return;session.active=false;session.endedAt=new Date().toISOString();await chrome.storage.local.set({attendanceEnabled:false});await persist();};
$("captureNow").onclick=captureNow;
$("saveRoster").onclick=async()=>{session ||= {name:"",active:false,observed:{},snapshots:0,aiMatches:{},manualMatches:{}};session.roster=rosterNames($("roster").value);session.aiMatches={};session.manualMatches={};await persist();};
$("clearRoster").onclick=async()=>{$("roster").value="";if(session){session.roster=[];session.aiMatches={};session.manualMatches={};await persist();}else render();};
$("rosterFile").onchange=async(event)=>{const file=event.target.files?.[0];if(!file)return;$("roster").value=await file.text();$("rosterCount").textContent=rosterNames($("roster").value).length;};
$("roster").oninput=()=>{$("rosterCount").textContent=rosterNames($("roster").value).length;};
$("saveKey").onclick=async()=>{const key=$("apiKey").value.trim();if(!key)return;apiKey=key;model=$("model").value.trim()||DEFAULT_MODEL;await chrome.storage.local.set({openRouterAPIKey:key,openRouterModel:model});$("apiKey").value="";$("keyStatus").textContent=`Key stored locally · ending ${key.slice(-4)}`;};
$("clearKey").onclick=async()=>{apiKey="";$("apiKey").value="";await chrome.storage.local.remove("openRouterAPIKey");$("keyStatus").textContent="No API key stored.";};
$("runAI").onclick=runAI;$("recalculate").onclick=render;$("exportCSV").onclick=exportCSV;
$("clearCaptured").onclick=async()=>{if(!session)return;session.observed={};session.aiMatches={};session.manualMatches={};session.snapshots=0;session.lastCapturedAt=null;await persist();};
chrome.storage.onChanged.addListener((changes,area)=>{if(area==="local"&&changes.attendanceSession){session=changes.attendanceSession.newValue;render();}});

chrome.storage.local.get({attendanceSession:null,openRouterAPIKey:"",openRouterModel:DEFAULT_MODEL},(stored)=>{session=stored.attendanceSession;apiKey=stored.openRouterAPIKey;model=stored.openRouterModel;$("model").value=model;if(apiKey)$("keyStatus").textContent=`Key stored locally · ending ${apiKey.slice(-4)}`;render();});
