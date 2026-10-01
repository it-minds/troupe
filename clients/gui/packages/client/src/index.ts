export * from "./types.js";
export { TroupeConnection, TroupeRpcError, TroupeConnectionClosed } from "./connection.js";
export type { ConnectOptions, ConnectionHooks } from "./connection.js";
export { PlaneClient, PlaneHttpError, normalizeEndpoint } from "./plane.js";
export type {
  Discovery,
  DeviceAuthorization,
  IdpTokens,
  PlaneCredential,
  Attachment,
  Me,
  Team,
  SessionRow,
  SessionsFilter,
  CreateSessionParams,
  ProfileOffering,
  WorkerPod,
} from "./plane.js";
export { SessionView, createLocalSession, turnCompleted } from "./session.js";
export type { SessionViewHooks, TurnResult } from "./session.js";
export { AuthSession, PlaneUnreachableError, memoryTokenStore, webTokenStore, currentOrigin } from "./auth.js";
export type { AuthSessionOptions, SignInProgress, TokenStore } from "./auth.js";
export { beginRedirect, completeRedirect, hasRedirectAnswer, scrubRedirect, idpMetadata, pkcePair } from "./pkce.js";
export type { BeginRedirectOptions, IdpMetadata, PkcePair, PendingRedirect, RedirectResult } from "./pkce.js";
export { SessionAttachment, waitOn } from "./attach.js";
export type { AttachOptions, AttachStatus } from "./attach.js";
export { ServerOffer, offeredName } from "./offer.js";
export type { OfferAsk, OfferOptions, OfferState } from "./offer.js";
export {
  fold,
  addPending,
  dropPending,
  emptyTranscript,
  isBlobRef,
  isRoot,
  isBusy,
  needsYou,
  rootState,
  openApprovals,
  openQuestions,
  loopEnding,
  settleLoop,
  LEGACY_BUDGET_OPTIONS,
} from "./transcript.js";
export type { Entry, TranscriptState, PendingInput, BlobRef, TodoItem, PresenceMember, QuestionOption, LoopState } from "./transcript.js";
export {
  FleetStore,
  PlaneSource,
  rowFromPlane,
  filterRows,
  awaitingApproval,
  awaitingYou,
  totalCostMicros,
  hasUnseen,
  describeUnseen,
  unseenSummary,
} from "./fleet.js";
export type { FleetRow, FleetSource, FleetFilter, FleetSnapshot, SessionKind, SyncState } from "./fleet.js";
export { AdminApi, bundleErrors, requiredRole } from "./admin.js";
export type {
  AdminFilter,
  AdminPod,
  AdminProfile,
  AdminSessionRow,
  AdminTeam,
  AdminTeamGroup,
  AdminTeamMember,
  TeamDisableEffect,
  AuditRow,
  BundleDetail,
  BundleSummary,
  FleetOverview,
  IdentityCheck,
  IdentityCheckResult,
  ProviderCheck,
  ProviderState,
  ScimConnector,
  SettingsList,
  PlatformSetting,
  ServicePrincipal,
  TeamSpend,
  Trigger,
  TriggerRun,
} from "./admin.js";
export { DaemonClient, DaemonSource, daemonUrl, rowFromDaemon } from "./daemon.js";
export type {
  CreateLocalParams,
  DaemonEndpoint,
  DaemonHooks,
  DaemonIdentity,
  DaemonSessionRow,
  ImportResult,
  LocalServer,
  LocalSkill,
  RecentWorkspace,
  RemoveResult,
  ScopedParams,
  ServerAuth,
  ServerTool,
  ServerToolResult,
  ServerTools,
  SignInStarted,
  SourceLayer,
  SourceScope,
  Worktree,
} from "./daemon.js";
export {
  MODEL_ROLES,
  PROVIDER_DEFAULT_URLS,
  applyClientDefaults,
  clientDefaults,
  configSetParams,
  describeOffer,
  describeOverride,
  discoveryParams,
  formFromConfig,
  modelConfigError,
  tokenCount,
} from "./config.js";
export type {
  ClientDefaults,
  ConfigOverride,
  ConfigSetParams,
  ModelAuth,
  ModelConfig,
  ModelDiscovery,
  ModelForm,
  ModelOffer,
  ModelProvider,
  ModelRole,
  ModelsParams,
} from "./config.js";
export { APPROVAL_CHOICES, PROVIDER_KINDS, describeCheck, nextStep, previousStep, setupError, setupUnsupported, vendorKeyVar } from "./setup.js";
export type {
  ProviderKind,
  SetupAnswer,
  SetupCheck,
  SetupCompleted,
  SetupDetected,
  SetupFlow,
  SetupSession,
  SetupStep,
  SetupStepName,
} from "./setup.js";
