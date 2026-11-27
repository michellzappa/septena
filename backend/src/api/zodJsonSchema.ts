// Zod (v3) to JSON Schema (draft 2020-12, the dialect of OpenAPI 3.1), for
// the generated `openapi.json` (ADR 0050 §5, scripts/gen-contract.ts).
//
// Zero dependencies: it reads the `_def` of each Zod type the /v1 validators
// use. A type it does not know throws, so a new validator shape fails the
// generator instead of writing a wrong schema. Refinements (`.refine`) have
// no JSON Schema form: the schema shows the shape, and the server still runs
// the refinement.

import type { ZodTypeAny } from "zod";

export type JsonSchema = Record<string, unknown>;

/// The schema of what a caller may send: a field with a default is optional.
/// The /v1 responses are not Zod-validated, so only requests are described.
export function zodToJsonSchema(schema: ZodTypeAny): JsonSchema {
  return convert(schema);
}

/// Whether a caller may leave the field out.
export function isOptional(schema: ZodTypeAny): boolean {
  const t = typeName(schema);
  if (t === "ZodOptional" || t === "ZodDefault") return true;
  if (t === "ZodEffects") return isOptional(def(schema).schema as ZodTypeAny);
  if (t === "ZodNullable" || t === "ZodBranded" || t === "ZodReadonly" || t === "ZodCatch") {
    return isOptional((def(schema).innerType ?? def(schema).type) as ZodTypeAny);
  }
  return false;
}

interface Def {
  typeName?: string;
  description?: string;
  [k: string]: unknown;
}

function def(s: ZodTypeAny): Def {
  return (s as unknown as { _def: Def })._def;
}

function typeName(s: ZodTypeAny): string {
  return def(s).typeName ?? "unknown";
}

function withDescription(s: ZodTypeAny, out: JsonSchema): JsonSchema {
  const d = def(s).description;
  return d ? { ...out, description: d } : out;
}

interface Check {
  kind: string;
  value?: unknown;
  regex?: RegExp;
  inclusive?: boolean;
}

function convert(s: ZodTypeAny): JsonSchema {
  const d = def(s);
  switch (d.typeName) {
    case "ZodString": {
      const out: JsonSchema = { type: "string" };
      const patterns: string[] = [];
      for (const c of (d.checks as Check[]) ?? []) {
        if (c.kind === "min") out.minLength = c.value;
        else if (c.kind === "max") out.maxLength = c.value;
        else if (c.kind === "length") out.minLength = out.maxLength = c.value;
        else if (c.kind === "regex" && c.regex) patterns.push(c.regex.source);
        else if (c.kind === "email") out.format = "email";
        else if (c.kind === "url") out.format = "uri";
        else if (c.kind === "uuid") out.format = "uuid";
        else if (c.kind === "datetime") out.format = "date-time";
        else if (c.kind === "trim" || c.kind === "toLowerCase" || c.kind === "toUpperCase") continue;
        else throw new Error(`zodToJsonSchema: string check "${c.kind}" has no mapping`);
      }
      if (patterns.length === 1) out.pattern = patterns[0];
      else if (patterns.length > 1) return withDescription(s, { allOf: patterns.map((pattern) => ({ ...out, pattern })) });
      return withDescription(s, out);
    }
    case "ZodNumber": {
      const out: JsonSchema = { type: "number" };
      for (const c of (d.checks as Check[]) ?? []) {
        if (c.kind === "int") out.type = "integer";
        else if (c.kind === "min") out[c.inclusive === false ? "exclusiveMinimum" : "minimum"] = c.value;
        else if (c.kind === "max") out[c.inclusive === false ? "exclusiveMaximum" : "maximum"] = c.value;
        else if (c.kind === "finite") continue;
        else throw new Error(`zodToJsonSchema: number check "${c.kind}" has no mapping`);
      }
      return withDescription(s, out);
    }
    case "ZodBoolean":
      return withDescription(s, { type: "boolean" });
    case "ZodNull":
      return withDescription(s, { type: "null" });
    case "ZodAny":
    case "ZodUnknown":
      return withDescription(s, {});
    case "ZodLiteral":
      return withDescription(s, { const: d.value });
    case "ZodEnum":
      return withDescription(s, { type: "string", enum: [...(d.values as string[])] });
    case "ZodArray": {
      const out: JsonSchema = { type: "array", items: convert(d.type as ZodTypeAny) };
      if (d.minLength) out.minItems = (d.minLength as { value: number }).value;
      if (d.maxLength) out.maxItems = (d.maxLength as { value: number }).value;
      if (d.exactLength) out.minItems = out.maxItems = (d.exactLength as { value: number }).value;
      return withDescription(s, out);
    }
    case "ZodObject": {
      const shape = (d.shape as () => Record<string, ZodTypeAny>)();
      const properties: Record<string, JsonSchema> = {};
      const required: string[] = [];
      for (const [key, value] of Object.entries(shape)) {
        properties[key] = convert(value);
        if (!isOptional(value)) required.push(key);
      }
      const out: JsonSchema = { type: "object", properties };
      if (required.length) out.required = required;
      const catchall = d.catchall as ZodTypeAny | undefined;
      if (catchall && typeName(catchall) !== "ZodNever") out.additionalProperties = convert(catchall);
      else if (d.unknownKeys === "strict") out.additionalProperties = false;
      return withDescription(s, out);
    }
    case "ZodRecord":
      return withDescription(s, { type: "object", additionalProperties: convert(d.valueType as ZodTypeAny) });
    case "ZodUnion":
    case "ZodDiscriminatedUnion": {
      const options = (Array.isArray(d.options) ? d.options : [...(d.options as Map<unknown, ZodTypeAny>).values()]) as ZodTypeAny[];
      return withDescription(s, { anyOf: options.map(convert) });
    }
    case "ZodIntersection":
      return withDescription(s, { allOf: [convert(d.left as ZodTypeAny), convert(d.right as ZodTypeAny)] });
    case "ZodTuple":
      return withDescription(s, { type: "array", prefixItems: (d.items as ZodTypeAny[]).map(convert), items: false });
    case "ZodOptional":
      return withDescription(s, convert(d.innerType as ZodTypeAny));
    case "ZodNullable": {
      const inner = convert(d.innerType as ZodTypeAny);
      return withDescription(s, { anyOf: [inner, { type: "null" }] });
    }
    case "ZodDefault": {
      const value = (d.defaultValue as () => unknown)();
      return withDescription(s, { ...convert(d.innerType as ZodTypeAny), default: value });
    }
    case "ZodEffects":
      return withDescription(s, convert(d.schema as ZodTypeAny));
    case "ZodBranded":
      return withDescription(s, convert(d.type as ZodTypeAny));
    case "ZodReadonly":
    case "ZodCatch":
      return withDescription(s, convert(d.innerType as ZodTypeAny));
    case "ZodPipeline":
      return withDescription(s, convert(d.in as ZodTypeAny));
    case "ZodLazy":
      return withDescription(s, convert((d.getter as () => ZodTypeAny)()));
    default:
      throw new Error(`zodToJsonSchema: Zod type "${d.typeName}" has no mapping`);
  }
}
