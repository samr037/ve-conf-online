// Shared assistant types (from Sources/VEKit/Assembler/AssistantAssembler.swift and Composer.swift).
import type { Value } from './value'

/** Assembler state per assistant (`$AssemblerState`, §11.1). */
export enum AssemblerState {
  developerBuild = 0,
  translatorBuild,
  backReadBuild,
  defaultBuild,
  build,
  userEntry,
  summary,
  buildUnknown,
}
export const keepsAnswers = (s: AssemblerState) => s >= 4

export type Precision = { k: 'decimals'; d: number } | { k: 'list' } | { k: 'time' }

export interface StepField {
  precision: Precision
  unitCode: string
  min: number
  max: number
  defaultValue: number
}

/** A wizard step declared by `.AID`. */
export interface AssistantStepDefinition {
  id: string
  stepName: string
  kind: 'E' | 'R' | 'C'
  inSummary: boolean
  /** entry: 1…4 fields; radio/check: one synthetic field */
  fields: StepField[]
  /** radio/check button count */
  buttons: number
}

export type Pending = { k: 'literal'; v: number } | { k: 'defaultValue' } | { k: 'minimum' } | { k: 'maximum' } | { k: 'previous' }

/** One assistant answer (§11.4). */
export interface AssistantAnswer {
  value: number
  previous: number
  hasALD: boolean
  confirmed: boolean
  pending?: Pending
  pendingAlsoPrevious: boolean
}

export const newAnswer = (value: number, previous: number): AssistantAnswer =>
  ({ value, previous, hasALD: false, confirmed: false, pendingAlsoPrevious: false })

/** Answers of one assistant, keyed by label name. Persist across builds: these are the user's choices. */
export interface AnswerTable {
  answers: Map<string, AssistantAnswer>
  steps: Map<string, AssistantStepDefinition>
  /** step ids in .AID order */
  order: string[]
}

export const newAnswerTable = (): AnswerTable => ({ answers: new Map(), steps: new Map(), order: [] })

export function cloneAnswerTable(t: AnswerTable): AnswerTable {
  const answers = new Map<string, AssistantAnswer>()
  for (const [k, a] of t.answers) answers.set(k, { ...a, pending: a.pending && { ...a.pending } })
  return { answers, steps: new Map(t.steps), order: [...t.order] }
}

export function cloneTables(t: Map<string, AnswerTable>): Map<string, AnswerTable> {
  const out = new Map<string, AnswerTable>()
  for (const [k, v] of t) out.set(k, cloneAnswerTable(v))
  return out
}

export type StepButtons = 'normal' | 'cancelOnly' | 'previousOnly' | 'nextOnly'

/** What the wizard UI is asked to show (states 5/6). */
export interface AssistantStepPresentation {
  assistant: string
  step: AssistantStepDefinition
  labels: string[]
  values: number[]
  format: Value[]
  buttons: StepButtons
  isFirst: boolean
}

export type AssistantDecision = { k: 'next'; values: number[] } | { k: 'previous' } | { k: 'cancel' }

export type MessageKind = 'message' | 'warning' | 'error' | 'fatal'

export interface AssemblerMessage {
  kind: MessageKind
  text: string
  position: string
}

/** The assembly pauses at each step it presents and resumes with the decision. */
export type AssemblyGen<R = void> = Generator<AssistantStepPresentation, R, AssistantDecision>
