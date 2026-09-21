"use strict";

const STATUS = Object.freeze({
  healthy: { label: "Healthy" },
  degraded: { label: "Degraded" },
  failed: { label: "Failed" },
  unknown: { label: "Unknown" },
  disabled: { label: "Disabled" },
  not_configured: { label: "Not configured" },
});

const state = { status: null, clients: null, config: null, health: null, errors: {}, refreshing: false };
const endpoints = Object.freeze({ status: "/api/v1/status", clients: "/api/v1/clients", config: "/api/v1/config", health: "/api/v1/health" });

function text(value) {
  if (value === null || value === undefined || value === "") return "Unavailable";
  if (Array.isArray(value)) return value.length ? value.join(", ") : "None observed";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  return String(value);
}

function statusState(value) { return Object.hasOwn(STATUS, value) ? value : "unknown"; }

function statusBadge(value) {
  const normalized = statusState(value);
  const badge = document.createElement("span");
  badge.className = "status";
  badge.dataset.state = normalized;
  badge.textContent = STATUS[normalized].label;
  if (value && normalized === "unknown" && value !== "unknown") badge.title = `Unrecognized state: ${value}`;
  return badge;
}

function checkState(value) {
  return value && typeof value === "object" ? value.state : value;
}

function addFact(list, label, value, status = false) {
  const term = document.createElement("dt");
  term.textContent = label;
  const detail = document.createElement("dd");
  detail.append(status ? statusBadge(checkState(value)) : document.createTextNode(text(value)));
  list.append(term, detail);
}

function summaryCard(title, primary, detail) {
  const card = document.createElement("article");
  card.className = "summary-card";
  const heading = document.createElement("h3");
  heading.textContent = title;
  const main = document.createElement("p");
  main.append(primary);
  const supporting = document.createElement("p");
  supporting.className = "muted";
  supporting.textContent = text(detail);
  card.append(heading, main, supporting);
  return card;
}

function renderOverview() {
  const snapshot = state.status;
  const grid = document.querySelector("#overview-grid");
  const overall = document.querySelector("#overall-status");
  grid.replaceChildren(); overall.replaceChildren();
  if (!snapshot) {
    overall.append(statusBadge("unknown"));
    grid.append(summaryCard("Operational data", document.createTextNode("Unavailable"), "The router state has not been inferred."));
    return;
  }
  overall.append(statusBadge(snapshot.overall));
  const runtime = snapshot.runtime || {};
  const wan = snapshot.wan || {};
  const lan = snapshot.lan || {};
  const services = snapshot.services || {};
  const serviceValues = Object.values(services);
  const healthyServices = serviceValues.filter((item) => checkState(item) === "healthy").length;
  const clients = state.clients && Array.isArray(state.clients.clients) ? state.clients.clients : snapshot.clients;
  grid.append(
    summaryCard("Runtime", document.createTextNode(text(runtime.recorded_status)), "Recorded lifecycle state"),
    summaryCard("WAN", statusBadge(checkState(wan.health)), `${text(wan.interface)} · ${text(wan.effective_ipv4)}`),
    summaryCard("LAN", statusBadge(checkState(lan.health)), `${text(lan.interface)} · ${text(lan.expected_ipv4)}`),
    summaryCard("Services", document.createTextNode(`${healthyServices} / ${serviceValues.length} healthy`), "Based on authoritative service checks"),
    summaryCard("Clients", document.createTextNode(Array.isArray(clients) ? String(clients.length) : "Unavailable"), "DHCP lease records; not an online count"),
  );
}

function renderNetwork() {
  const snapshot = state.status || {};
  const config = state.config && state.config.config ? state.config.config : {};
  const wan = snapshot.wan || {};
  const lan = snapshot.lan || {};
  const wanList = document.querySelector("#wan-details");
  const lanList = document.querySelector("#lan-details");
  wanList.replaceChildren(); lanList.replaceChildren();
  addFact(wanList, "Interface", wan.interface || config.wan_interface);
  addFact(wanList, "Mode", wan.mode || config.wan_mode);
  addFact(wanList, "Expected IPv4", wan.effective_ipv4);
  addFact(wanList, "Observed IPv4", wan.observed_ipv4);
  addFact(wanList, "IPv4 assessment", wan.ipv4_health, true);
  addFact(wanList, "Gateway", wan.effective_gateway);
  addFact(wanList, "Interface health", wan.health, true);
  addFact(wanList, "Gateway reachability", wan.gateway_reachability, true);
  addFact(wanList, "Internet probe", wan.internet_reachability, true);
  addFact(lanList, "Interface", lan.interface || config.lan_interface);
  addFact(lanList, "Configured subnet", config.lan_subnet);
  addFact(lanList, "Expected IPv4", lan.expected_ipv4);
  addFact(lanList, "Observed IPv4", lan.observed_ipv4);
  addFact(lanList, "IPv4 assessment", lan.ipv4_health, true);
  addFact(lanList, "Interface health", lan.health, true);
  addFact(lanList, "Health target", lan.target || config.lan_health_target);
  addFact(lanList, "ICMP evidence", lan.icmp, true);
  addFact(lanList, "Neighbor evidence", lan.neighbor_reachability, true);
  addFact(lanList, "Raw NUD state", lan.target_neighbor_state);
}

function renderClients() {
  const body = document.querySelector("#clients-body");
  const count = document.querySelector("#client-count");
  body.replaceChildren();
  const clients = state.clients && Array.isArray(state.clients.clients) ? state.clients.clients : null;
  count.textContent = clients ? `${clients.length} lease record${clients.length === 1 ? "" : "s"}` : "Data unavailable";
  if (!clients || clients.length === 0) {
    const row = document.createElement("tr");
    const cell = document.createElement("td");
    cell.colSpan = 5; cell.textContent = clients ? "No DHCP lease records" : "Management data unavailable";
    row.append(cell); body.append(row); return;
  }
  for (const client of clients) {
    const row = document.createElement("tr");
    const lease = client.lease_expired ? "Expired" : (client.lease_expiry === 0 ? "No expiry" : text(client.lease_expiry));
    for (const value of [client.hostname, client.ipv4, client.mac, lease, client.neighbor_state]) {
      const cell = document.createElement("td"); cell.textContent = text(value); row.append(cell);
    }
    body.append(row);
  }
}

function renderServices() {
  const grid = document.querySelector("#services-grid");
  grid.replaceChildren();
  const services = state.status && state.status.services;
  if (!services || typeof services !== "object") {
    grid.append(summaryCard("Service data", statusBadge("unknown"), "Management data unavailable")); return;
  }
  for (const [name, check] of Object.entries(services).sort()) {
    const card = document.createElement("article"); card.className = "service-card";
    const heading = document.createElement("h3"); heading.textContent = name.replaceAll("-", " ");
    const detail = document.createElement("p"); detail.className = "muted"; detail.textContent = text(check && check.detail);
    card.append(heading, statusBadge(checkState(check)), detail); grid.append(card);
  }
}

function renderSystem() {
  const runtime = state.status && state.status.runtime ? state.status.runtime : {};
  const config = state.config && state.config.config ? state.config.config : {};
  const runtimeList = document.querySelector("#runtime-details");
  const managementList = document.querySelector("#management-details");
  runtimeList.replaceChildren(); managementList.replaceChildren();
  addFact(runtimeList, "Recorded status", runtime.recorded_status);
  addFact(runtimeList, "Deployment mode", runtime.deployment_mode || config.deployment_mode);
  addFact(runtimeList, "Profile", runtime.profile);
  addFact(runtimeList, "Started at", runtime.started_at);
  addFact(runtimeList, "Owned stages", runtime.owned_stages);
  addFact(managementList, "API", state.health ? "Available" : "Unavailable");
  addFact(managementList, "API version", state.health && state.health.api_version);
  addFact(managementList, "Access", "IPv4 loopback only");
  addFact(managementList, "Mode", "Read only");
  addFact(managementList, "Generated at", state.status && state.status.generated_at);
}

function render() {
  renderOverview(); renderNetwork(); renderClients(); renderServices(); renderSystem();
  const failures = Object.keys(state.errors);
  const warning = document.querySelector("#data-warning");
  warning.hidden = failures.length === 0;
  warning.textContent = failures.length ? `Management data unavailable from: ${failures.join(", ")}. Other successful views remain current; this does not mean the router failed.` : "";
}

async function fetchDocument(name, path) {
  const response = await fetch(path, { cache: "no-store", headers: { Accept: "application/json" } });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const documentValue = await response.json();
  if (!documentValue || typeof documentValue !== "object" || Array.isArray(documentValue)) throw new Error("invalid document");
  return documentValue;
}

async function refresh() {
  if (state.refreshing) return;
  state.refreshing = true;
  const button = document.querySelector("#refresh");
  const message = document.querySelector("#refresh-state");
  button.disabled = true; message.textContent = "Refreshing management data…";
  const results = await Promise.allSettled(Object.entries(endpoints).map(async ([name, path]) => [name, await fetchDocument(name, path)]));
  state.errors = {};
  for (const result of results) {
    if (result.status === "fulfilled") state[result.value[0]] = result.value[1];
    else {
      const index = results.indexOf(result);
      const name = Object.keys(endpoints)[index];
      state[name] = null; state.errors[name] = true;
    }
  }
  state.refreshing = false; button.disabled = false;
  message.textContent = `Last refresh ${new Date().toLocaleTimeString()}`;
  render();
}

function selectView() {
  const requested = location.hash.slice(1);
  const view = ["overview", "network", "clients", "services", "system"].includes(requested) ? requested : "overview";
  for (const section of document.querySelectorAll("[data-view]")) section.hidden = section.dataset.view !== view;
  for (const link of document.querySelectorAll("[data-view-link]")) {
    if (link.dataset.viewLink === view) link.setAttribute("aria-current", "page"); else link.removeAttribute("aria-current");
  }
  document.querySelector("#content").focus({ preventScroll: true });
}

document.querySelector("#refresh").addEventListener("click", refresh);
window.addEventListener("hashchange", selectView);
selectView();
refresh();
setInterval(refresh, 30000);
