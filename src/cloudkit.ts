// CloudKit Web Services client — Worker edition.
// Ported from /Users/mz/Dev/septena-mcp/src/cloudkit.ts; uses Web Fetch,
// no Node APIs. Auth is API token (env) + per-request ckWebAuthToken.

import type { Env } from "./env.js";

const HOST = "https://api.apple-cloudkit.com";

export interface CKRecord {
  recordName: string;
  recordType: string;
  fields: Record<string, { value: unknown; type?: string }>;
}

export interface CKQueryResponse {
  records: CKRecord[];
  continuationMarker?: string;
}

export interface CKFilter {
  fieldName: string;
  comparator:
    | "EQUALS" | "NOT_EQUALS"
    | "LESS_THAN" | "LESS_THAN_OR_EQUALS"
    | "GREATER_THAN" | "GREATER_THAN_OR_EQUALS"
    | "BEGINS_WITH";
  fieldValue: { value: unknown };
}

export interface CKSort {
  fieldName: string;
  ascending?: boolean;
}

export class CloudKitClient {
  constructor(
    private env: Env,
    private ckWebAuthToken: string,
  ) {}

  get zoneName(): string {
    return this.env.CK_ZONE;
  }

  private url(rest: string): string {
    const u = new URL(
      `${HOST}/database/1/${this.env.CK_CONTAINER}/${this.env.CK_ENVIRONMENT}/private/${rest}`,
    );
    u.searchParams.set("ckAPIToken", this.env.CK_API_TOKEN);
    u.searchParams.set("ckWebAuthToken", this.ckWebAuthToken);
    return u.toString();
  }

  async post<T = unknown>(rest: string, payload: unknown): Promise<T> {
    const res = await fetch(this.url(rest), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const text = await res.text();
    if (!res.ok) {
      throw new CloudKitError(res.status, text);
    }
    return text ? (JSON.parse(text) as T) : ({} as T);
  }

  async queryRecords(args: {
    recordType: string;
    filterBy?: CKFilter[];
    sortBy?: CKSort[];
    resultsLimit?: number;
  }): Promise<CKQueryResponse> {
    // CloudKit caps each response at ~200 records and returns a
    // continuationMarker for the rest. Follow it until the caller's
    // resultsLimit is reached or the server says we're done.
    const target = args.resultsLimit ?? 200;
    const collected: CKRecord[] = [];
    let continuationMarker: string | undefined;

    do {
      const remaining = target - collected.length;
      const page = await this.post<CKQueryResponse>("records/query", {
        zoneID: { zoneName: this.env.CK_ZONE },
        query: {
          recordType: args.recordType,
          filterBy: args.filterBy,
          sortBy: args.sortBy,
        },
        resultsLimit: Math.min(remaining, 200),
        ...(continuationMarker ? { continuationMarker } : {}),
      });
      collected.push(...page.records);
      continuationMarker = page.continuationMarker;
    } while (continuationMarker && collected.length < target);

    return {
      records: collected,
      continuationMarker, // may be defined if caller hit their own limit
    };
  }
}

/// Resolve the CloudKit userRecordName for a ckWebAuthToken via the
/// authenticated users/current endpoint. The multi-user identity anchor:
/// only a device signed into that iCloud account can mint a token for it,
/// and CloudKit tells us whose it is. Returns null if the token is
/// invalid/expired — callers reject rather than bind to an unknown user.
export async function fetchUserRecordName(env: Env, ckWebAuthToken: string): Promise<string | null> {
  const url = new URL(
    `${HOST}/database/1/${env.CK_CONTAINER}/${env.CK_ENVIRONMENT}/private/users/current`,
  );
  url.searchParams.set("ckAPIToken", env.CK_API_TOKEN);
  url.searchParams.set("ckWebAuthToken", ckWebAuthToken);
  const res = await fetch(url.toString(), { headers: { Accept: "application/json" } });
  if (!res.ok) return null;
  const body = (await res.json().catch(() => null)) as { userRecordName?: string } | null;
  return body?.userRecordName ?? null;
}

// ----------------------------------------------------------------------
// queryByDateRange — unified STRING-date range query
//
// CloudKit's per-field Queryable/Sortable flags are auto-managed by the
// iOS client. We can't depend on any given STRING field (`date`) being
// range-indexed, and `___createTime` is not queryable on most record
// types. Manually flipping flags in CK Dashboard is out of scope.
//
// So: match-all on the date STRING field with `BEGINS_WITH ""` (which
// only requires the field to be queryable at all — true for every record
// type that has a STRING date), then filter the YYYY-MM-DD window in JS.
// YMD strings compare lexicographically, so `>=`/`<=` work directly.
//
// Use this for every *_list tool that takes from/to/date over a STRING
// `date` field. TIMESTAMP fields (e.g. NutritionEntry.loggedAt) don't
// have the same indexing issue and should keep their server-side range.
export interface QueryByDateRangeArgs {
  recordType: string;
  /** STRING field holding YYYY-MM-DD. Defaults to "date". */
  dateField?: string;
  /** Inclusive lower bound, YYYY-MM-DD. */
  from: string;
  /** Inclusive upper bound, YYYY-MM-DD. */
  to: string;
  /** Extra EQUALS-style filters on indexed fields. */
  extraFilters?: CKFilter[];
  /** Max records to return *after* the client-side date filter. */
  resultsLimit?: number;
  /** Optional secondary sort field (e.g. "time" — applied client-side). */
  timeField?: string;
}

export async function queryByDateRange(
  client: CloudKitClient,
  args: QueryByDateRangeArgs,
): Promise<CKRecord[]> {
  const dateField = args.dateField ?? "date";
  const limit = args.resultsLimit ?? 200;

  // BEGINS_WITH "" matches every record with a value in dateField — works
  // without any range index on that field, and lets extraFilters narrow
  // the result set server-side when those fields are indexed.
  const filterBy: CKFilter[] = [
    { fieldName: dateField, comparator: "BEGINS_WITH", fieldValue: { value: "" } },
    ...(args.extraFilters ?? []),
  ];

  // No server-side sortBy — `date`/`time` aren't reliably marked Sortable.
  // Pull a generous page (capped at the caller's limit times a small
  // multiplier so a wide window can still return `limit` matches when the
  // record type has lots of out-of-window history).
  const fetchLimit = Math.max(limit, 200);
  const res = await client.queryRecords({
    recordType: args.recordType,
    filterBy,
    resultsLimit: fetchLimit,
  });

  const { from, to } = args;
  const filtered = res.records.filter((r) => {
    const v = r.fields[dateField]?.value;
    return typeof v === "string" && v >= from && v <= to;
  });

  filtered.sort((a, b) => {
    const ad = (a.fields[dateField]?.value as string) ?? "";
    const bd = (b.fields[dateField]?.value as string) ?? "";
    if (ad !== bd) return ad < bd ? 1 : -1;
    if (args.timeField) {
      const at = (a.fields[args.timeField]?.value as string) ?? "";
      const bt = (b.fields[args.timeField]?.value as string) ?? "";
      if (at !== bt) return at < bt ? 1 : -1;
    }
    return 0;
  });

  return filtered.slice(0, limit);
}

export class CloudKitError extends Error {
  constructor(public status: number, public body: string) {
    super(`CloudKit ${status}: ${body.slice(0, 200)}`);
  }
  /** Indicates the ckWebAuthToken is no longer valid — caller should force re-auth. */
  get isAuthExpired(): boolean {
    return this.status === 401 || /AUTHENTICATION_(FAILED|REQUIRED)/.test(this.body);
  }
}

// ----------------------------------------------------------------------
// Resilient writes: createWithFieldFallback
//
// Problem: CloudKit Web Services rejects writes to fields the schema
// doesn't yet know about. CloudKit fields are auto-registered only when
// the native SDK (iOS app) writes them. For a brand-new account that has
// never used a section in the app, every optional field on that section's
// records is invisible to the API. The result is a "Field foo not found"
// error that aborts the whole write — even though `foo` is a real,
// schema-declared optional field on the Swift side.
//
// Approach: try the write; on unknown-field error, parse the field name
// from the error message, drop it, retry. Loop until success, until a
// protected (caller-required) field would be dropped, or until we hit a
// non-field error. Return the set of dropped fields so the caller can
// surface them to the model — useful for the LLM to mention to the user.
//
// This is whack-a-mole, but it terminates: there are finitely many fields,
// and dropping one strictly shrinks the field set. The cost is
// roundtrip(s) on first call per (user × type × unregistered field).
// Once the field gets registered (typically by the user's first in-app
// write of that field), retries stop happening for that user.

export interface ResilientCreateInput {
  recordType: string;
  recordName: string;
  fields: Record<string, { value: unknown }>;
  /** Field names that must NOT be dropped. If the server complains about one of these, the call fails. */
  protectedFields?: string[];
}

export interface ResilientCreateResult {
  /** Field names that were dropped because the server didn't recognise them. */
  droppedFields: string[];
}

interface CKModifyResponseMinimal {
  records: Array<{ recordName: string; serverErrorCode?: string; reason?: string }>;
}

/** Parse the offending field name out of a CloudKit error message. */
export function extractUnknownFieldName(message: string): string | null {
  const patterns = [
    // "Field 'foo' not found in NutritionEntry"
    /\bfield\s+['"`]?([a-zA-Z_][a-zA-Z0-9_]*)['"`]?\s+(?:not found|unknown|is not defined|is undefined|does not exist)/i,
    // "Unknown field foo"
    /\bunknown\s+field\s+['"`]?([a-zA-Z_][a-zA-Z0-9_]*)['"`]?/i,
    // "No such field foo"
    /\bno\s+such\s+field\s+['"`]?([a-zA-Z_][a-zA-Z0-9_]*)['"`]?/i,
    // "Invalid field foo"
    /\binvalid\s+field\s+['"`]?([a-zA-Z_][a-zA-Z0-9_]*)['"`]?/i,
  ];
  for (const p of patterns) {
    const m = message.match(p);
    if (m && m[1]) return m[1];
  }
  return null;
}

// Augment CloudKitClient with the resilient-create helper. Declared as a
// separate prototype assignment so it stays close to the error-parsing
// helper above without bloating the class body.
declare module "./cloudkit.js" {
  interface CloudKitClient {
    createWithFieldFallback(input: ResilientCreateInput): Promise<ResilientCreateResult>;
  }
}

CloudKitClient.prototype.createWithFieldFallback = async function(
  this: CloudKitClient,
  input: ResilientCreateInput
): Promise<ResilientCreateResult> {
  const protectedSet = new Set(input.protectedFields ?? []);
  const dropped: string[] = [];
  // Clone — we mutate `currentFields` across retries, but the caller's
  // input must stay untouched in case they want to inspect/log it.
  let currentFields: Record<string, { value: unknown }> = { ...input.fields };

  // Bounded loop: each iteration either succeeds or drops one field.
  // +1 so we always get one final attempt after the last possible drop.
  const maxAttempts = Object.keys(currentFields).length + 1;

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    let errorMessage: string;
    try {
      const res = await this.post<CKModifyResponseMinimal>("records/modify", {
        zoneID: { zoneName: this.zoneName },
        operations: [{
          operationType: "create",
          record: {
            recordType: input.recordType,
            recordName: input.recordName,
            fields: currentFields,
          },
        }],
      });
      const code = res.records[0]?.serverErrorCode;
      if (!code) return { droppedFields: dropped };
      errorMessage = res.records[0]?.reason ?? code;
    } catch (e) {
      // CloudKitError or generic — let the error-parser try either way.
      if (e instanceof CloudKitError) errorMessage = e.body;
      else if (e instanceof Error)    errorMessage = e.message;
      else                            errorMessage = String(e);
    }

    const unknownField = extractUnknownFieldName(errorMessage);
    if (unknownField && unknownField in currentFields && !protectedSet.has(unknownField)) {
      dropped.push(unknownField);
      delete currentFields[unknownField];
      continue;
    }
    // Not a recoverable field error, or the offending field is protected.
    throw new Error(errorMessage);
  }

  throw new Error("createWithFieldFallback: max attempts exceeded");
};
