// One session, read like a chat (docs/design/session-chat.dc.html): a one-line head, the
// transcript in one centred column, the cards that wait on the person at its foot, and the
// composer in one box under it. The backstage and the scratchpad are under the head's ⋯.
//
// The three primary things are the only ones guaranteed on screen at 380px, because
// they are the only three a person ever *has* to do: read what happened, decide, and
// reply. Tasks, files and who is working live in the backstage track, shown on asking,
// which on a phone is a sheet over the whole screen.
//
// Nothing here is held that a reconnect could not rebuild. A message the person sends
// renders as Queued until the server echoes it back — not inserted optimistically into
// the stream, because the stream's order is the server's and a reconnect must not
// reshuffle what somebody has already read.

import { Fragment, memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { JSX, ReactNode } from "react";
import {
  ALLOW_ALWAYS,
  PlaneOwn,
  RELAYED_ALLOW_SESSION,
  UPLOAD_ARTIFACT,
  archiveRefusal,
  markRefusal,
  bytes,
  configKey,
  errorText,
  isBusy,
  isRoot,
  mayArchive,
  needsYou,
  onThisComputer,
  openApprovals,
  openQuestions,
  named,
  nameOrSubject,
  presentMembers,
  repairable,
  severalSteer,
  rootState,
  scratchVersion,
  repositoriesOf,
  repositoryParam,
  repositoryRefusal,
  sessionWhose,
  settleLoop,
  stoppedSentence,
  TAKE_BACK_LINE,
  giveLine,
  teamWords,
  unseenSummary,
  visibilityRefusal,
  behind,
  configurationLine,
  owedLine,
  raiseKept,
  raiseRefusal,
  remoteWhen,
  updateLine,
  versionOf,
  LIFESPAN_CHOICES,
  lifespanItem,
  lifespanMark,
  lifespanOf,
  lifespanRefusal,
  throwawaySentence,
  SENSITIVE_CONFIRM,
  SENSITIVE_ITEM,
  sensitiveBanner,
  sensitiveMark,
  sensitiveRefusal,
} from "@troupe/client";
import type {
  Artifact,
  AttachStatus,
  AuthSession,
  ContextFill,
  DaemonClient,
  Entry,
  FleetRow,
  Lifespan,
  LoopInfo,
  OwnPlane,
  ScratchDocument,
  SessionRepository,
  SessionKind,
  SessionView,
  TranscriptState,
} from "@troupe/client";
import { useLifespans, useSensitive, useSessionView, useStartQuestions, useTeams } from "../hooks";
import { useNarrow } from "../narrow";
import type { Marks, SessionHandle } from "../hooks";
import { curtainLine, curtainUp, DEFAULT_DETAIL, isDetail, layout, waitingOn, waitingWords } from "../frames";
import type { Detail, Drawn, LayoutCache } from "../frames";
import { holdPlace } from "../anchor";
import { copyText } from "../clipboard";
import { saveFile, shell } from "../shell";
import { AgentSwitch, sessionAgents } from "./AgentSwitch";
import { ApprovalPanel, DecisionRecord } from "./Approval";
import type { Audiences } from "./Approval";
import { AnswerRecord, QuestionPanel } from "./Question";
import { ProposalCard } from "./Proposal";
import type { ProposalActions } from "./Proposal";
import { SessionRepositories, teamRepositories } from "./Repositories";
import type { ChosenRepository } from "./Repositories";
import { CommandPalette } from "./CommandPalette";
import type { PaletteScreen, Sides } from "./CommandPalette";
import { Files } from "./Files";
import { PodConfig } from "./PodConfig";
import { Publish } from "./Publish";
import { Curtain, InlineMarkdown, Markdown, ProseFrame, ReasoningFrame, StripLine, ToolFrame, useNow } from "./Frames";
import { GoalLine, LoopStatus } from "./Goal";
import { LocalControls } from "./LocalControls";
import { Instructions } from "./Instructions";
import { MemoryPane } from "./Memory";
import type { MemoryAsk } from "./Memory";
import { OfferLine, OfferPanel } from "./Offer";
import { SessionServers } from "./SessionServers";
import { onboardingNote, StartLine, StartPanel } from "./Onboard";
import { inviteLine, RemoteLine, RemoteOfferControl } from "./Remote";
import { InviteControl } from "./Invites";
import { archiveItem, Cost, Dialog, initials, Loading, personColour, Pill, Sync, When, Where } from "./bits";
import { Mask } from "./brand";
import { RenameField } from "./Rename";
import { Tasks } from "./Tasks";
import type { TodoEdit } from "./Tasks";

/**
 * A backstage pane: the running order, the files, what the instructions are read from, the
 * repository's memory, or for a team session what is in force in it on its pod.
 */
type Pane = "tasks" | "files" | "instructions" | "memory" | "settings";

/** A line this app says in the transcript, after the event it was said at. */
interface Note {
  after: number;
  text: string;
}

export function Session({
  auth,
  daemon,
  machineUser,
  row,
  sessionId,
  created,
  startedIn,
  onBack,
  onArchive,
  marks,
  onGo,
  sides,
  onAgents,
  onStarted,
  onProfile,
}: {
  /** The plane, for a team session. Null in local mode. */
  auth: AuthSession | null;
  daemon: DaemonClient | null;
  /** Who the daemon records this person as, which is "you" in a session on this computer. */
  machineUser: string | null;
  row: FleetRow | undefined;
  sessionId: string;
  /** Where it was just made, for a session opened straight from the start screen. */
  created?: SessionKind | undefined;
  /** The workspace a session on this computer was just started in, from the start screen: its start goes on to the librarian. */
  startedIn?: string | undefined;
  onBack: () => void;
  /** Archive the session (`true`) or unarchive it, where it runs; it rejects with the server's refusal. */
  onArchive?: ((on: boolean) => Promise<void>) | undefined;
  /** Rename the session and keep it at the top of the list, where it runs: its owner's. */
  marks?: Marks | undefined;
  /** Leave for another screen, for the palette's Navigate and Setup commands. */
  onGo?: (screen: PaletteScreen) => void;
  /** The sides this install has, so the palette lists only the commands of those. */
  sides: Sides;
  /** Open the agents manager on this session's workspace, at one agent if named: a session on this computer's. */
  onAgents?: ((agent?: string) => void) | undefined;
  /** Open a session the agent picker started, as the start screen opens one it made. */
  onStarted?: ((id: string, kind: SessionKind, workspace?: string) => void) | undefined;
  /** Open the page saying what a plane profile gives a session: a team session's. */
  onProfile?: ((name: string) => void) | undefined;
}): JSX.Element {
  // Where it runs decides which socket it is reached over and nothing else about this
  // screen: the transcript, the approvals and the composer are the same protocol either
  // way, which is the whole point of the client library. A session the list has not
  // caught up with yet is where the start screen just made it, if it came from there, and
  // otherwise a team session only where there is a team to have one.
  const kind = row?.kind ?? created ?? (auth ? "team" : "local");
  const view = useSessionView(auth, sessionId, { daemon, kind });
  // The conversation is the screen: the backstage (tasks, files, instructions, memory,
  // settings) is a press away under the head's ⋯, and starts hidden at every width.
  const [backstage, setBackstage] = useState(false);
  const [pane, setPane] = useState<Pane>("tasks");
  // What `/memory refresh` or `/memory forget` asked of the memory pane, until it takes it.
  const [memoryAsk, setMemoryAsk] = useState<MemoryAsk | null>(null);
  // The command palette: over the screen (Ctrl-K), or over the composer (its `/`).
  const [palette, setPalette] = useState<"screen" | "composer" | null>(null);
  // The publish dialog, empty, or with a reply's Markdown as its one file.
  const [publishing, setPublishing] = useState<{ text?: string } | null>(null);
  // The scratchpad document open beside the conversation, by name; null while it is closed.
  const [scratch, setScratch] = useState<string | null>(null);
  useEffect(() => setScratch(null), [sessionId]);
  // On a phone the backstage and the scratchpad are sheets over the whole screen, one at a
  // time: opening one shuts the other. Beside the conversation both may be open.
  const narrow = useNarrow();
  const showBackstage = (on: boolean): void => {
    setBackstage(on);
    if (on && narrow) setScratch(null);
  };
  // The same function from one event to the next, so a turn nothing changed is not drawn anew.
  const showScratch = useCallback(
    (name: string | null): void => {
      setScratch(name);
      if (name !== null && narrow) setBackstage(false);
    },
    [narrow],
  );
  // On this computer, through its daemon; a team session and a laptop's relayed one are
  // reached through the plane, and the person is who the plane says.
  const here = onThisComputer(kind);
  const self = (!here ? auth?.me?.subject : (machineUser ?? auth?.me?.subject)) ?? undefined;

  // A relayed session shared to observe is read here as a viewer's is.
  const readOnly = row?.state === "read_only" || row?.yourRole === "viewer" || row?.yourRole === "observe";
  const dormant = row?.state === "dormant";
  // What the harness proposes is the owner's to answer (troupe #1208): a yes to the plane as
  // them, a no to the session. The same object from one draw to the next, so no turn is
  // drawn anew for it.
  const owner = kind === "team" && self !== undefined && (row?.owner === self || row?.yourRole === "owner");
  const answering = view.view;
  const proposalActions = useMemo<ProposalActions | undefined>(() => {
    if (!owner || !auth || !answering) return undefined;
    return {
      accept: async (id, edits) => {
        await auth.plane.acceptProposal(await auth.token(), sessionId, id, edits);
      },
      answer: (id, decision) => answering.answerProposal(id, decision),
    };
  }, [owner, auth, answering, sessionId]);
  // A root that ended so the harness drops what is sent to it (a spent budget, a refusal):
  // the composer gives way to the sentence that says so. One that finished keeps it, since
  // a message resumes it.
  const stopped = stoppedSentence(view.state);
  const open = openApprovals(view.state);
  // The clock, while a prompt or a request has drawn nothing: the composer's hint says so.
  const waitNow = useNow(waitingOn(view.state, Date.now()) !== null);
  const waiting = waitingWords(view.state, waitNow);
  // Whom a publication may be for, asked only once an agent asks to publish: through the
  // daemon's sign-in as the person's artifacts are listed, or what the plane said of them.
  const audiences = useAudiences(daemon, auth, open.some((e) => e.publication !== undefined));
  // Everyone else here, by name: who could answer an approval first, and who reads
  // what is sent.
  const others = presentMembers(view.state).filter((p) => p.subject !== self).map((p) => p.display_name ?? p.subject);
  // The loop as its events say, and as the session answers for the one case they cannot:
  // a session that stopped mid-loop records the interruption only when it wakes.
  const loop = settleLoop(view.state.loop, useLoopAnswer(view.view));
  const [away, seenAway] = useAway(sessionId, row);
  // Archiving it, from the ⋯ or the palette: what a refusal said, until the next try.
  const [archiveError, setArchiveError] = useState<string | null>(null);
  useEffect(() => setArchiveError(null), [sessionId]);
  const archive = onArchive
    ? async (on: boolean): Promise<string | null> => {
        setArchiveError(null);
        try {
          await onArchive(on);
          return null;
        } catch (e) {
          const why = archiveRefusal(e, on);
          setArchiveError(`It was not ${on ? "archived" : "unarchived"}. ${why}.`);
          return why;
        }
      }
    : undefined;
  // Its name and its place at the top of the list, from the ⋯ or the palette, as archiving
  // is: the owner's, where the session has a list. The name is a field in the head while
  // it is being changed.
  const [renaming, setRenaming] = useState(false);
  const [markError, setMarkError] = useState<string | null>(null);
  useEffect(() => {
    setMarkError(null);
    setRenaming(false);
  }, [sessionId]);
  const marking = marks && row && !row.archived && mayArchive(row) ? { marks, row } : undefined;
  const rename = marking
    ? async (title: string): Promise<string | null> => {
        setMarkError(null);
        try {
          await marking.marks.rename(marking.row, title);
          return null;
        } catch (e) {
          const why = markRefusal(e, "rename");
          setMarkError(`It was not renamed. ${why}.`);
          return why;
        }
      }
    : undefined;
  const keep = marking
    ? async (on: boolean): Promise<string | null> => {
        setMarkError(null);
        try {
          await marking.marks.keep(marking.row, on);
          return null;
        } catch (e) {
          const why = markRefusal(e, on ? "keep" : "let go");
          setMarkError(`It was not ${on ? "kept at the top" : "let go from the top"}. ${why}.`);
          return why;
        }
      }
    : undefined;
  // Whose a pod session is (troupe #1169): the plane's row, then the log's word once its
  // owner changes it, and the answer to a change made here until the log says it too. The
  // owner gives it to the team or takes it back from the ⋯ or `/share`.
  const rowSaid = row?.raw as { team?: string | null } | undefined;
  const [answered, setAnswered] = useState<{ visibility: string; seen: string | undefined } | null>(null);
  const [shareError, setShareError] = useState<string | null>(null);
  const [shareWaiting, setShareWaiting] = useState<string | null>(null);
  useEffect(() => {
    setAnswered(null);
    setShareError(null);
    setShareWaiting(null);
  }, [sessionId]);
  const visibility = answered && view.state.visibility === answered.seen ? answered.visibility : (view.state.visibility ?? row?.visibility ?? undefined);
  const team = rowSaid?.team ?? null;
  const whose = row?.kind === "team" ? sessionWhose(visibility, row.yourRole === "owner") : null;
  // The row as the head marks it: "only you" in place of "Team" follows the visibility now.
  const headRow = row && visibility ? { ...row, visibility } : row;
  const share =
    marking && marking.row.kind === "team" && (visibility === "team" || visibility === "private")
      ? async (to: "team" | "private"): Promise<string | null> => {
          setShareError(null);
          setShareWaiting(null);
          try {
            const waiting = await marking.marks.share(marking.row, to);
            // A sensitive session's profile asks a team administrator first: nothing
            // changed yet, and the head says it waits.
            if (waiting) {
              setShareWaiting(waiting);
              return waiting;
            }
            setAnswered({ visibility: to, seen: view.state.visibility });
            return null;
          } catch (e) {
            const why = visibilityRefusal(e, to === "team");
            setShareError(why);
            return why;
          }
        }
      : undefined;
  // Sensitive (troupe #1239): the log's mark, else the row's, else the answer to a mark made
  // here. Nothing clears it, so whichever says it first holds. Its owner marks a pod session
  // from the ⋯, asked once more, where the plane knows sensitive sessions.
  const knowsSensitive = useSensitive(auth);
  const [sensitiveError, setSensitiveError] = useState<string | null>(null);
  const [askSensitive, setAskSensitive] = useState(false);
  useEffect(() => {
    setSensitiveError(null);
    setAskSensitive(false);
  }, [sessionId]);
  const sensitive = view.state.sensitive ?? row?.sensitive ?? null;
  const markWords = { self: self ?? null, nameOf: (s: string) => (s === row?.owner ? row?.ownerName : null) };
  const sensitiveTag = sensitiveMark({ sensitive }, markWords);
  const makeSensitive =
    marking && marking.row.kind === "team" && marking.row.yourRole === "owner" && knowsSensitive && !sensitive
      ? async (): Promise<void> => {
          setSensitiveError(null);
          try {
            await marking.marks.sensitive(marking.row);
          } catch (e) {
            setSensitiveError(sensitiveRefusal(e));
          } finally {
            setAskSensitive(false);
          }
        }
      : undefined;
  // How long it lasts (troupe #1209): the answer to a change made here until the log says
  // it too, then the log's word, else the row's. Its owner changes it from the ⋯, where the
  // server knows lifespans; a throwaway one's head offers Erase now and Keep it.
  const lifespans = useLifespans(auth, daemon);
  const [lived, setLived] = useState<{ lifespan: Lifespan; seen: string | undefined } | null>(null);
  const [lifespanError, setLifespanError] = useState<string | null>(null);
  useEffect(() => {
    setLived(null);
    setLifespanError(null);
  }, [sessionId]);
  const lifespan: Lifespan = lived && view.state.lifespan === lived.seen ? lived.lifespan : lifespanOf(view.state.lifespan ?? row?.lifespan);
  const relive =
    marking && lifespans(marking.row.kind)
      ? async (to: Lifespan): Promise<string | null> => {
          setLifespanError(null);
          try {
            await marking.marks.relive(marking.row, to);
            setLived({ lifespan: to, seen: view.state.lifespan });
            return null;
          } catch (e) {
            const why = lifespanRefusal(e);
            setLifespanError(why);
            return why;
          }
        }
      : undefined;
  const eraseNow =
    marking && lifespan === "throwaway"
      ? async (): Promise<void> => {
          setLifespanError(null);
          try {
            await marking.marks.erase(marking.row);
            onBack();
          } catch (e) {
            setLifespanError(`It was not erased: ${errorText(e)}.`);
          }
        }
      : undefined;
  // Which configuration a pod session runs on (troupe #1177): the log's version once it
  // names one, else the row's, beside the version its channel would start a session on now.
  // Its owner updates it from the panel; a raise kept while the agent works says so there.
  const pinRow = row?.raw as { bundle_version?: unknown; bundle_current?: unknown; bundle_raise_to?: unknown } | undefined;
  const [raiseError, setRaiseError] = useState<string | null>(null);
  useEffect(() => setRaiseError(null), [sessionId]);
  const pinned = versionOf(view.state.bundleVersion) ?? versionOf(pinRow?.bundle_version);
  const owed = versionOf(pinRow?.bundle_raise_to);
  const configuration: Configuration | undefined =
    row?.kind === "team" && pinned !== null
      ? {
          version: pinned,
          current: versionOf(pinRow?.bundle_current),
          owed: owed !== null && owed > pinned ? owed : null,
          busy: isBusy(view.state),
          onUpdate:
            marking && row.yourRole === "owner"
              ? async () => {
                  setRaiseError(null);
                  try {
                    await marking.marks.raise(marking.row);
                  } catch (e) {
                    if (raiseKept(e) === null) setRaiseError(raiseRefusal(e));
                  }
                }
              : undefined,
        }
      : undefined;
  // The GitHub repositories a pod session holds (troupe #1207), as its row says them; its
  // owner attaches one from what the team lists, and takes one off.
  const teamRows = useTeams(row?.kind === "team" ? auth : null);
  const repositories: RepositoriesPanel | undefined =
    row?.kind === "team"
      ? {
          held: repositoriesOf(row.raw),
          listed: teamRepositories(teamRows, team),
          owner: row.yourRole === "owner" && marking !== undefined,
          onAttach: marking
            ? async (r: ChosenRepository) => {
                try {
                  await marking.marks.repository(marking.row, { attach: repositoryParam(r) });
                  return null;
                } catch (e) {
                  return repositoryRefusal(e, true);
                }
              }
            : undefined,
          onTakeOff: marking
            ? async (name: string) => {
                try {
                  await marking.marks.repository(marking.row, { takeOff: name });
                  return null;
                } catch (e) {
                  return repositoryRefusal(e, false);
                }
              }
            : undefined,
        }
      : undefined;
  // Onboarding, then the brief, as the session's start found them due (Decision 835), and
  // the librarian for a session started here; what they came to is said in the transcript.
  const start = useStartQuestions(daemon, sessionId, view.state.onboarding, { local: here, canAnswer: !readOnly, startedIn });
  const notes = useStartNotes(daemon, sessionId, start.state?.said, view.state.lastSeq);
  // The start's suggestion in this app's words: the panel's answers while it asks them.
  const suggested = view.state.onboarding;
  const startWords = suggested ? { seq: suggested.seq, text: onboardingNote(suggested, start.state?.asking ?? null) } : undefined;
  // The panels under the transcript give way to it, down to their header and answers.
  const column = useRef<HTMLDivElement>(null);
  useHeldPanels(column);
  // Where a session on this computer works: what the start screen was told, what the list
  // says, or what the start's event named; the memory pane asks about its repository.
  const workspace =
    !here ? undefined : (startedIn ?? (row?.raw as { workspace?: string } | undefined)?.workspace ?? view.state.onboarding?.workspace);
  // The palette's agent rows carry their facts from the daemon's `agents.list` for this
  // workspace (troupe #565); a session on the platform has its commands.list alone.
  const agentRows = useMemo(() => (daemon && workspace ? () => daemon.listAgents(workspace).then((r) => r.agents) : undefined), [daemon, workspace]);
  const planeLinked = useMemo(() => (daemon ? () => daemon.identity().then((i) => i.linked === true) : undefined), [daemon]);
  // What the head's agent switch offers, which the palette's agent rows switch to.
  const switchWorkspace = here ? (workspaceOf(row) ?? workspace ?? null) : null;
  const listAgents = useMemo(
    () => {
      const v = view.view;
      return v ? () => sessionAgents(v, daemon, here, switchWorkspace) : undefined;
    },
    [view.view, daemon, here, switchWorkspace],
  );
  // How much of each turn is open: the config ladder's `transcript.detail`, unless `/detail`
  // chose for this session (troupe #474).
  const detail = useDetail(daemon, workspace, sessionId);
  // A file the agent made, saved on this computer: its bytes read with `fs.read` from
  // wherever the session runs (a pod's workspace as a local checkout), then the system's
  // save dialog. What happened, in a line for the transcript to say beside it.
  const sessionView = view.view;
  const saveReady = useCallback(
    async (path: string): Promise<string> => {
      if (!sessionView) return "not saved: the session is not open yet";
      try {
        const file = await sessionView.fsRead(path);
        const where = await saveFile(path.split("/").pop() || path, file.content);
        return where ? `saved to ${where}` : "not saved";
      } catch (e) {
        return `not saved: ${errorText(e)}`;
      }
    },
    [sessionView],
  );

  // Ctrl-K (⌘K on a Mac) opens the command palette from anywhere on the screen, from the
  // moment it is drawn: a layout effect, since a passive one runs a while after the screen
  // shows on a busy machine, and a Ctrl-K pressed meanwhile was lost.
  useLayoutEffect(() => {
    const onKey = (e: KeyboardEvent): void => {
      if ((e.ctrlKey || e.metaKey) && !e.altKey && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPalette("screen");
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const current = agentOf(view.state, row);
  // Whether the server writes a lasting rule from an approval (troupe #920): asked of what it
  // said at `initialize`, so the answer appears the day it does.
  const alwaysAllow = Boolean(sessionView?.capabilities[ALLOW_ALWAYS]);
  // A laptop's session through the plane is answered once, unless its daemon takes an answer
  // for the rest of the session from there (troupe #932).
  const onceOnly = kind === "remote" && sessionView?.capabilities[RELAYED_ALLOW_SESSION] !== true;
  // Where the person's artifacts are listed from for the composer's "Add from artifacts":
  // the plane they are signed in to, for a session there; this computer's daemon otherwise.
  const own = useMemo<OwnPlane | null>(() => (!here && auth ? new PlaneOwn((method, params) => auth.rpc(method, params), auth.planeUrl) : daemon), [here, auth, daemon]);
  // A reply's Retry sends the person's words again, as a new turn.
  const send = view.send;
  const retry = useCallback((text: string) => send(text), [send]);
  const goSetup = useMemo(() => (onGo ? () => onGo("setup") : undefined), [onGo]);
  const publishReply = useMemo(() => (daemon ? (text: string) => setPublishing({ text }) : undefined), [daemon]);

  const commands = palette ? (
    <CommandPalette
      view={view}
      local={here}
      anchored={palette === "composer"}
      onClose={() => setPalette(null)}
      actions={{
        go: (screen) => (screen === "sessions" ? onBack() : onGo?.(screen)),
        sides,
        showFiles: () => {
          showBackstage(true);
          setPane("files");
        },
        showMemory: (what) => {
          showBackstage(true);
          setPane("memory");
          if (what) setMemoryAsk((a) => ({ what, n: (a?.n ?? 0) + 1 }));
        },
        transcript: () => transcriptText(view.state),
        detail: detail.command,
        ...(here && onAgents ? { agents: () => onAgents() } : {}),
        ...(agentRows ? { agentRows } : {}),
        ...(daemon ? { publish: () => setPublishing({}) } : {}),
        ...(planeLinked ? { planeLinked } : {}),
        ...(listAgents ? { sessionAgents: listAgents } : {}),
        ...(readOnly ? {} : { switchAgent: async (name: string) => void (await view.switchProfile(name)) }),
        currentAgent: current,
        ...(archive
          ? {
              archive: async (on: boolean) => {
                if (row && Boolean(row.archived) === on) return on ? "this session is already archived" : "this session is not archived";
                const why = await archive(on);
                return why ?? (on ? undefined : "unarchived: it is back in the session list");
              },
            }
          : {}),
        ...(rename
          ? {
              rename: async (name: string) => {
                if (name === "") return void setRenaming(true);
                // Renamed, the head says so: the palette closes on it.
                return (await rename(name)) ?? undefined;
              },
            }
          : {}),
        ...(keep
          ? {
              keep: async (on: boolean) => {
                if (row && row.pinned === on) return on ? "this session is already kept at the top" : "this session is not kept at the top";
                const why = await keep(on);
                return why ?? (on ? "kept at the top of the session list" : "let go from the top");
              },
            }
          : {}),
        ...(row?.kind === "team"
          ? {
              share: async (to: "team" | "private" | null) => {
                if (to === null) return whoseLine(visibility, team, row.yourRole === "owner");
                if (!share) return "only its owner gives this session to the team or takes it back";
                if (visibility === to) return to === "team" ? `it is ${teamWords(team)}'s already` : "only you and the people you invited can open it already";
                const why = await share(to);
                return why ?? (to === "team" ? `given to ${teamWords(team)}` : "only you again: the invitations stay");
              },
            }
          : {}),
        lifespan: async (to: Lifespan | null) => {
          const mark = lifespanMark({ lifespan, erasesAt: row?.erasesAt ?? null }) ?? "normal";
          if (to === null) return `this session is ${mark}`;
          if (!relive) return "only its owner says how long this session lasts, where its server knows lifespans";
          if (lifespan === to) return `this session is ${to} already`;
          const why = await relive(to);
          return why ?? `this session is ${to} now`;
        },
      }}
    />
  ) : null;

  return (
    <section className="session">
      {palette === "screen" && commands}
      {publishing && daemon && (
        <Publish daemon={daemon} sessionId={here ? sessionId : undefined} reply={publishing.text} onClose={() => setPublishing(null)} />
      )}

      <Header
        row={headRow}
        sessionId={sessionId}
        state={view.state}
        self={self}
        agent={current}
        onBack={onBack}
        renaming={rename && renaming ? { onRename: async (title) => void (await rename(title)), onDone: () => setRenaming(false) } : null}
        lasts={lifespan === "persistent" ? "persistent" : null}
        sensitive={sensitiveTag}
        invites={row ? <InviteControl auth={auth} daemon={daemon} row={row} onWaiting={setShareWaiting} /> : null}
        remoteLine={row?.kind === "remote" ? <RemoteLine row={row} /> : null}
        menu={
          <SessionMenu
            sessionId={sessionId}
            row={row}
            detail={detail.level}
            onFold={detail.fold}
            backstage={backstage}
            onToggleBackstage={() => showBackstage(!backstage)}
            scratchpad={
              view.state.scratch.length > 0
                ? { open: scratch !== null, onToggle: () => showScratch(scratch === null ? latest(view.state.scratch) : null) }
                : null
            }
            onAbout={here && onAgents && current ? () => onAgents(current) : undefined}
            onArchive={archive && mayArchive(row) ? (on) => void archive(on) : undefined}
            onRename={rename ? () => setRenaming(true) : undefined}
            onKeep={keep ? (on) => void keep(on) : undefined}
            sharing={share && (visibility === "team" || visibility === "private") ? { visibility, team, onShare: (to) => void share(to) } : undefined}
            living={relive ? { lifespan, onRelive: (to) => void relive(to) } : undefined}
            onSensitive={makeSensitive ? () => setAskSensitive(true) : undefined}
            whose={whose}
            remote={
              row && daemon && auth && (row.kind === "local" || row.kind === "private") ? (
                <RemoteOfferControl daemon={daemon} row={row} presence={view.state.presence} />
              ) : null
            }
          />
        }
      />

      {/* The goal, set with /goal and cleared with /goal clear, one line under the head while
          there is one, and the loop that works towards it beside it. */}
      {(view.state.goal || loop?.state === "running") && (
        <div className="goal-bar">
          <GoalLine goal={view.state.goal} loop={loop} canChange={!readOnly} onSet={view.setGoal} onClear={view.clearGoal} onStartLoop={view.startLoop} />
          <LoopStatus loop={loop} canStop={!readOnly} onStop={view.stopLoop} />
        </div>
      )}

      {row?.archived && (
        <div className="banner dormant" role="status">
          <p>This session is archived: it is kept whole, and not in the session list.{mayArchive(row) ? " Unarchive it from ⋯ to put it back." : ""}</p>
        </div>
      )}
      {archiveError && (
        <div className="banner error" role="alert">
          <p>{archiveError}</p>
        </div>
      )}
      {markError && (
        <div className="banner error" role="alert">
          <p>{markError}</p>
        </div>
      )}
      {shareError && (
        <div className="banner error" role="alert">
          <p>{shareError}</p>
        </div>
      )}
      {sensitive && (
        <div className="banner sensitive" role="status">
          <p>{sensitiveBanner(sensitive, markWords)}</p>
        </div>
      )}
      {shareWaiting && (
        <div className="banner sensitive" role="status">
          <p>{shareWaiting}</p>
        </div>
      )}
      {sensitiveError && (
        <div className="banner error" role="alert">
          <p>{sensitiveError}</p>
        </div>
      )}
      {askSensitive && makeSensitive && (
        <Dialog label={SENSITIVE_ITEM.title} role="alertdialog" onClose={() => setAskSensitive(false)} className="sensitive-confirm">
          <h1>{SENSITIVE_ITEM.title}</h1>
          <p>{SENSITIVE_CONFIRM}</p>
          <div className="actions">
            <button type="button" onClick={() => setAskSensitive(false)}>
              Cancel
            </button>
            <button type="button" className="primary" onClick={() => void makeSensitive()}>
              {SENSITIVE_ITEM.title}
            </button>
          </div>
        </Dialog>
      )}
      {lifespan === "throwaway" && !row?.archived && (
        <Throwaway erasesAt={row?.erasesAt ?? null} onErase={eraseNow} onKeep={relive ? () => void relive("normal") : undefined} />
      )}
      {lifespanError && (
        <div className="banner error" role="alert">
          <p>{lifespanError}</p>
        </div>
      )}
      {raiseError && (
        <div className="banner error" role="alert">
          <p>{raiseError}</p>
        </div>
      )}
      <Banners
        status={view.status}
        detail={view.detail}
        dormant={dormant}
        readOnly={readOnly}
        error={view.error}
        profile={kind === "team" ? (row?.profile ?? null) : null}
      />
      <OfferLine offer={view.offer} />
      {/* Your own servers as this session on this computer has them. */}
      {here && daemon && (
        <SessionServers daemon={daemon} sessionId={sessionId} workspace={workspaceOf(row) ?? workspace ?? null} onManage={onGo ? () => onGo("connect") : undefined} />
      )}
      <StartLine state={start.state} />
      {away && <Away summary={away} onSeen={seenAway} />}

      <div className="stagearea">
        <div className="conversation" ref={column}>
          <Stream
            key={sessionId}
            seed={sessionId}
            state={view.state}
            notes={notes}
            startWords={startWords}
            self={self}
            local={kind === "local"}
            detail={detail.level}
            readBlob={view.readBlob}
            onSetup={goSetup}
            onScratch={showScratch}
            onSave={saveReady}
            onRetry={readOnly ? undefined : (stopped ?? retry)}
            onPublish={publishReply}
            onProposal={readOnly ? undefined : proposalActions}
            owner={owner}
            earlier={view.earlier}
            onEarlier={view.loadEarlier}
          />

          {/* Cards at the foot of the transcript, where the eye already is; sticky, so
              scrolling up to read the context never loses the decision. */}
          {open.map((entry) => (
            <ApprovalPanel
              key={entry.callId}
              entry={entry}
              canAnswer={!readOnly}
              others={others}
              onAnswer={(d, a) => view.respond(entry.callId, d, a)}
              onDefinition={here ? onAgents : undefined}
              onceOnly={onceOnly}
              alwaysAllow={alwaysAllow}
              audiences={audiences}
            />
          ))}

          {/* The agent's questions and the harness's budget question, in the same place. */}
          {openQuestions(view.state).map((entry) => (
            <QuestionPanel key={entry.callId} entry={entry} canAnswer={!readOnly} onAnswer={(text) => view.answer(entry.callId, text)} />
          ))}

          {/* The session's question about your own servers, before it takes their tools. */}
          {view.offer.state === "asking" && <OfferPanel key={view.offer.ask.tools.join(" ")} ask={view.offer.ask} onAnswer={view.answerOffer} />}

          {/* What the start found due on this computer: onboarding, then the brief. */}
          {start.state && <StartPanel state={start.state} onAnswer={start.answer} />}

          {readOnly ? (
            <ReadOnly />
          ) : stopped ? (
            <Stopped sentence={stopped} />
          ) : (
            <Composer
              view={view}
              daemon={daemon}
              own={own}
              here={here}
              dormant={dormant}
              busy={isBusy(view.state)}
              waiting={waiting}
              looping={loop?.state === "running"}
              live={view.status === "live"}
              others={others}
              profile={kind === "team" ? (row?.profile ?? null) : null}
              context={view.state.context}
              agent={
                <AgentSwitch
                  view={view}
                  auth={auth}
                  daemon={daemon}
                  kind={kind}
                  workspace={switchWorkspace}
                  planeProfile={kind === "team" ? (row?.profile ?? null) : null}
                  current={current}
                  canChange={!readOnly}
                  onStarted={onStarted}
                />
              }
              commands={palette === "composer" ? commands : null}
              onCommands={() => setPalette((p) => (p === "composer" ? null : "composer"))}
              onSent={seenAway}
            />
          )}
        </div>

        {scratch !== null && <Scratchpad view={view.view} docs={view.state.scratch} open={scratch} onOpen={showScratch}onClose={() => setScratch(null)} />}

        {backstage && (
          <Backstage
            view={view}
            daemon={daemon}
            row={row}
            configuration={configuration}
            repositories={repositories}
            onEditTodo={!readOnly && view.view ? (action, params) => view.view!.editTodo(action, params) : undefined}
            self={self}
            selfName={named(auth?.me?.display_name, auth?.me?.subject)}
            pane={pane}
            onPane={setPane}
            onClose={() => setBackstage(false)}
            memory={
              daemon && here
                ? {
                    daemon,
                    workspace,
                    sessionId,
                    librarians: start.state?.librarian ? [start.state.librarian] : [],
                    ask: memoryAsk,
                    onAsked: () => setMemoryAsk(null),
                  }
                : null
            }
            onOpenMemory={onGo ? () => onGo("memory") : undefined}
            onProfile={onProfile}
          />
        )}
      </div>
    </section>
  );
}

/**
 * Holds each panel in the conversation's column (an approval, a question, an offer, the
 * start's questions) at least as tall as its header, its answers and its body's minimum,
 * as they are drawn now. The panel shrinks as a flex item so the transcript keeps its
 * minimum and the composer stays on the screen, its body scrolling; CSS alone cannot say
 * where to stop, since a panel's floor is the height of its header and answers, which
 * wrap with the column's width. Below the floor the column scrolls instead, the panel
 * sticky at its bottom, and nothing overlaps.
 */
function useHeldPanels(column: { current: HTMLElement | null }): void {
  useLayoutEffect(() => {
    const el = column.current;
    if (!el) return;
    const px = (v: string): number => parseFloat(v) || 0;
    const hold = (): void => {
      for (const panel of el.querySelectorAll<HTMLElement>(":scope > .approval")) {
        const body = panel.querySelector<HTMLElement>(":scope > .panel-body");
        if (!body) continue;
        const style = getComputedStyle(panel);
        const parts = [...panel.children] as HTMLElement[];
        let floor = px(style.paddingTop) + px(style.paddingBottom) + px(style.borderTopWidth) + px(style.borderBottomWidth) + px(style.rowGap) * (parts.length - 1);
        for (const part of parts) floor += part === body ? px(getComputedStyle(body).minHeight) : part.offsetHeight;
        panel.style.minHeight = `${Math.ceil(floor)}px`;
      }
    };
    hold();
    // A browser without the observers (the tests' page) keeps the floor it was given once.
    if (typeof ResizeObserver === "undefined" || typeof MutationObserver === "undefined") return;
    // The column's width, and each header's and answers' height (a font arriving, a line wrapping).
    const sizes = new ResizeObserver(hold);
    const watch = (): void => {
      sizes.disconnect();
      sizes.observe(el);
      for (const part of el.querySelectorAll(":scope > .approval > :not(.panel-body)")) sizes.observe(part);
    };
    watch();
    // A panel comes and goes, or what it says changes; the transcript's own changes are not its.
    const panels = new MutationObserver((changes) => {
      if (changes.every((c) => c.target instanceof Element && c.target.closest(".stream"))) return;
      watch();
      hold();
    });
    panels.observe(el, { childList: true, subtree: true });
    return () => {
      sizes.disconnect();
      panels.disconnect();
    };
  }, [column]);
}

// The start's lines by daemon connection and session, each where it was said, for as long
// as the app runs: a session left and opened again shows them where they were, not under
// its replay's head.
const anchored = new WeakMap<DaemonClient, Map<string, Note[]>>();

/**
 * The start's lines (what onboarding did, the librarian it started or why none), each
 * placed after the event the transcript had reached when it was said, as the terminal
 * client writes them into the session's window as it goes. They are this app's, not the
 * session's log, so a start asked again (the app opened again) has its own.
 */
function useStartNotes(daemon: DaemonClient | null, sessionId: string, said: string[] | undefined, lastSeq: number): Note[] {
  const [, redraw] = useState(0);
  const at = useRef(lastSeq);
  at.current = lastSeq;
  useEffect(() => {
    if (!daemon || !said) return;
    const notes = anchored.get(daemon) ?? new Map<string, Note[]>();
    anchored.set(daemon, notes);
    const had = notes.get(sessionId) ?? [];
    const same = had.length <= said.length && had.every((n, i) => n.text === said[i]);
    if (same && had.length === said.length) return;
    const kept = same ? had : [];
    notes.set(sessionId, [...kept, ...said.slice(kept.length).map((text) => ({ after: at.current, text }))]);
    redraw((n) => n + 1);
  }, [daemon, sessionId, said]);
  // A line said before the transcript had reached any event, its replay slower than the
  // start's questions, goes where the transcript has reached once it reaches one: after
  // the session's first line, not above it for good.
  useEffect(() => {
    if (!daemon || lastSeq === 0) return;
    const notes = anchored.get(daemon);
    const had = notes?.get(sessionId);
    if (!notes || !had?.some((n) => n.after === 0)) return;
    notes.set(sessionId, had.map((n) => (n.after === 0 ? { ...n, after: lastSeq } : n)));
    redraw((n) => n + 1);
  }, [daemon, sessionId, lastSeq]);
  return (daemon && anchored.get(daemon)?.get(sessionId)) || [];
}

// The level `/detail` chose, by daemon connection and session, for as long as the app
// runs: the view is this app's own business, so nothing is written to the session's log or
// to a file. A team session with no daemon here keeps its choice under `nowhere`.
const chosen = new WeakMap<object, Map<string, Detail>>();
const nowhere = {};

function choices(daemon: DaemonClient | null): Map<string, Detail> {
  const owner = daemon ?? nowhere;
  const had = chosen.get(owner);
  if (had) return had;
  const made = new Map<string, Detail>();
  chosen.set(owner, made);
  return made;
}

/**
 * How much of a transcript is open (troupe #474): `transcript.detail` as the config ladder
 * has it for the session's workspace, which the daemon answers from every layer, read when
 * the daemon is reached and again when a `transcript` key changes, and quiet with no daemon
 * to ask; and `/detail`'s choice for this session over it.
 * `command` is the palette's `/detail`, `fold` the ⋯ menu's fold of every turn's working.
 */
function useDetail(
  daemon: DaemonClient | null,
  workspace: string | undefined,
  sessionId: string,
): { level: Detail; command: (args: string) => string | undefined; fold: (folded: boolean) => void } {
  const [setting, setSetting] = useState<Detail>(DEFAULT_DETAIL);
  const [choice, setChoice] = useState<Detail | undefined>(() => choices(daemon).get(sessionId));
  useEffect(() => setChoice(choices(daemon).get(sessionId)), [daemon, sessionId]);

  useEffect(() => {
    if (!daemon) return;
    let live = true;
    const read = (): void => {
      daemon
        .modelConfig(workspace)
        .then((config) => {
          const value = configKey(config, "transcript.detail")?.value;
          if (live) setSetting(isDetail(value) ? value : DEFAULT_DETAIL);
        })
        .catch(() => undefined);
    };
    read();
    const stop = daemon.onConfigChanged((changed) => {
      if (changed.keys.some((k) => k === "transcript" || k.startsWith("transcript."))) read();
    });
    return () => {
      live = false;
      stop();
    };
  }, [daemon, workspace]);

  const command = useCallback(
    (args: string): string | undefined => {
      if (args === "") {
        return choice ? `transcript detail: ${choice}, for this session (the setting says ${setting})` : `transcript detail: ${setting} (the transcript.detail setting)`;
      }
      if (!isDetail(args)) return "usage: /detail [quiet | tools | everything]";
      choices(daemon).set(sessionId, args);
      setChoice(args);
      return undefined;
    },
    [choice, setting, daemon, sessionId],
  );

  // The ⋯ menu's fold is the same choice: folded is quiet, unfolded is everything, which is
  // what a click on one turn's strip opens it to; the setting's own level may be quiet, and
  // unfolding to it would open nothing.
  const fold = useCallback(
    (folded: boolean): void => {
      const level: Detail = folded ? "quiet" : "everything";
      choices(daemon).set(sessionId, level);
      setChoice(level);
    },
    [daemon, sessionId],
  );

  return { level: choice ?? setting, command, fold };
}

/** What was said, for `/copy`: the people's and the agent's words, not the tool traffic. */
function transcriptText(state: TranscriptState): string {
  return state.entries
    .flatMap((e) => (e.kind === "user" ? [`${e.authorName ?? e.author ?? "You"}: ${e.text}`] : e.kind === "assistant" ? [`Troupe: ${e.text}`] : []))
    .join("\n\n");
}

/**
 * The agent a window runs: as its transcript says (`session_created`, then each
 * `profile_switched`), and until that has arrived, as a daemon's row says it. A plane's row
 * names the plane's profile, which is not an agent, so it is not shown as one.
 */
function agentOf(state: TranscriptState, row: FleetRow | undefined): string | null {
  return state.profile ?? (row && onThisComputer(row.kind) ? row.profile : null) ?? null;
}

/** Where a session on this computer works, as its row says. */
function workspaceOf(row: FleetRow | undefined): string | null {
  const workspace = (row?.raw as { workspace?: unknown } | undefined)?.workspace;
  return typeof workspace === "string" && workspace ? workspace : null;
}

/**
 * The head, one line: back, the mask and the title, the session's setup as tags (where it
 * runs, its plane profile, the agent this window runs), then who is here, the status,
 * Invite, and ⋯ for the rest. On a phone the tags give way and the title keeps what is left.
 */
function Header({
  row,
  sessionId,
  state,
  self,
  agent,
  onBack,
  renaming,
  lasts,
  sensitive,
  invites,
  remoteLine,
  menu,
}: {
  row: FleetRow | undefined;
  sessionId: string;
  state: TranscriptState;
  self: string | undefined;
  /** The agent this window runs. */
  agent: string | null;
  onBack: () => void;
  /** The title as a field while it is being renamed, from the ⋯ or /rename; null otherwise. */
  renaming?: { onRename: (title: string) => Promise<void>; onDone: () => void } | null;
  /** `persistent`, the head's mark of a session kept until erased; null otherwise, a throwaway one's line under the head saying it whole. */
  lasts?: string | null;
  /** `sensitive` and since when, by what (troupe #1239); null for a session that is not, which shows nothing. */
  sensitive?: { word: string; title: string } | null;
  /** Whom it is shared with by name, and for its owner the invitation (troupe #765). */
  invites?: JSX.Element | null;
  /** Whose laptop a relayed session is on. */
  remoteLine?: JSX.Element | null;
  /** The ⋯ menu: the backstage, the scratchpad, steering from elsewhere, the session's facts. */
  menu: JSX.Element;
}): JSX.Element {
  const working = rootState(state);
  const here = presentMembers(state);
  const title = row?.title ?? sessionId;

  return (
    <header className="session-head">
      <button type="button" className="back" onClick={onBack} aria-label="Back to all sessions">
        ←<span className="wide"> Sessions</span>
      </button>
      <span className="head-mask" aria-hidden="true">
        <Mask size={22} />
      </span>
      {renaming ? (
        <RenameField title={row?.title ?? ""} onRename={renaming.onRename} onDone={renaming.onDone} />
      ) : (
        <h1 className="title" title={title}>
          {title}
        </h1>
      )}
      <div className="crumbs">
        {row && (
          <>
            <Where kind={row.kind} row={row} />
            {/* How a private session's sealing stands here, as its row in the list says. */}
            <Sync state={row.sync} device={row.device} />
          </>
        )}
        {/* Before the profile and the agent, which the composer says too, so a narrow head
            clips those and not this. */}
        {lasts && (
          <span className="tag lasts" title={lasts === "persistent" ? "Kept until its owner erases it" : "Erased a while after it goes quiet, unless somebody keeps it"}>
            {lasts}
          </span>
        )}
        {sensitive && (
          <span className="tag sensitive" title={sensitive.title}>
            {sensitive.word}
          </span>
        )}
        {row?.kind === "team" && row.profile && (
          <span className="tag" title={`${row.profile}: the plane profile this session runs on; a session keeps the one it started with`}>
            {row.profile}
          </span>
        )}
        <span className="tag profile" title={agent ? `${agent}: the agent this window runs` : "The agent this window runs"}>
          {agent ?? "—"}
        </span>
        {remoteLine}
      </div>
      <span className="spacer" />

      <div className="controls">
        {here.length > 0 && <Here members={here} self={self} />}
        {state.doneReason ? (
          // A root the harness wakes no more has stopped, and says why; one that finished
          // is resumed by the next message.
          stoppedSentence(state) ? (
            <Pill status="error" title={stoppedSentence(state)}>
              Stopped
            </Pill>
          ) : (
            <Pill status="allowed">Finished</Pill>
          )
        ) : state.failed ? (
          // The root kept crashing and the session stopped on it: a failure, with what it
          // raised, and not a rest.
          <Pill status="error" title={state.failed.detail}>
            Failed
          </Pill>
        ) : needsYou(state) ? (
          <Pill status="waiting">Needs you</Pill>
        ) : isBusy(state) ? (
          <Pill status="running">{working === "compacting" ? "Tidying up" : "Working"}</Pill>
        ) : (
          <Pill status="idle">Idle</Pill>
        )}
        {invites}
        {menu}
      </div>
    </header>
  );
}

/**
 * A throwaway session's line under the head (troupe #1209): when it goes, and to its owner
 * Erase now, asked once more since it cannot be undone, and Keep it, which makes it normal.
 */
function Throwaway({
  erasesAt,
  onErase,
  onKeep,
}: {
  erasesAt: string | null;
  onErase?: (() => Promise<void>) | undefined;
  onKeep?: (() => void) | undefined;
}): JSX.Element {
  const [asking, setAsking] = useState(false);
  return (
    <div className="banner throwaway" role="status">
      <p>{asking ? "Erase it now? Its log, its workspace and its key go, and it cannot be undone." : throwawaySentence(erasesAt)}</p>
      {asking && onErase ? (
        <>
          <button type="button" className="link" onClick={() => void onErase()}>
            Erase it
          </button>
          <button type="button" className="link" onClick={() => setAsking(false)}>
            Cancel
          </button>
        </>
      ) : (
        <>
          {onErase && (
            <button type="button" className="link" onClick={() => setAsking(true)}>
              Erase now
            </button>
          )}
          {onKeep && (
            <button type="button" className="link" onClick={onKeep}>
              Keep it
            </button>
          )}
        </>
      )}
    </div>
  );
}

/** What `/share` alone says of a pod session: whose it is, and to its owner what changes it. */
function whoseLine(visibility: string | undefined, team: string | null, owner: boolean): string {
  if (visibility === "team") return `given to ${teamWords(team)}: everyone on it can open it, and steer it where the team allows${owner ? "; /share me takes it back" : ""}`;
  if (visibility === "private" && owner) return `only you and the people you invited can open it; /share team gives it to ${teamWords(team)}`;
  if (visibility === "private") return "only its owner and the people they invited can open it";
  return "the plane has not said whose this session is";
}

/** What every turn shows at the level in force, under the fold in the ⋯ menu. */
const WORKING_NOW: Record<Detail, string> = {
  quiet: "Now quiet: each turn's thinking and tool steps are in its strip",
  tools: "Now tools: each turn's tool steps are open, its thinking shut",
  everything: "Now everything: each turn's thinking and tool steps are open",
};

/**
 * The head's ⋯: every turn's working folded and unfolded, at the level `/detail` sets; the
 * backstage and the scratchpad, shown and hidden; steering this session
 * from another device; the agent in the agents manager; and the session's facts (its id,
 * your part in it, who invited you). It stays mounted while shut, so a dialog opened from
 * it outlives it.
 */
function SessionMenu({
  sessionId,
  row,
  detail,
  onFold,
  backstage,
  onToggleBackstage,
  scratchpad,
  onAbout,
  onArchive,
  onRename,
  onKeep,
  sharing,
  living,
  onSensitive,
  whose,
  remote,
}: {
  sessionId: string;
  row: FleetRow | undefined;
  /** How much of each turn is open; and folding every turn's working (`true`) or unfolding it. */
  detail: Detail;
  onFold: (folded: boolean) => void;
  backstage: boolean;
  onToggleBackstage: () => void;
  /** Whether the scratchpad is open, and the switch; null while it has no document. */
  scratchpad: { open: boolean; onToggle: () => void } | null;
  /** Open the agent in the agents manager: a session on this computer's. */
  onAbout?: (() => void) | undefined;
  /** Archive it (`true`) or unarchive it: its owner's alone. */
  onArchive?: ((on: boolean) => void) | undefined;
  /** Turn the title into a field to rename it: its owner's alone. */
  onRename?: (() => void) | undefined;
  /** Keep it at the top of the session list (`true`) or let it go: its owner's alone. */
  onKeep?: ((on: boolean) => void) | undefined;
  /** Give a pod session to its team or take it back: its owner's alone. */
  sharing?: { visibility: "team" | "private"; team: string | null; onShare: (to: "team" | "private") => void } | undefined;
  /** How long it lasts, and the change to either of the other two: its owner's alone. */
  living?: { lifespan: Lifespan; onRelive: (to: Lifespan) => void } | undefined;
  /** Ask to mark it sensitive, one-way: its owner's alone, and gone once it is. */
  onSensitive?: (() => void) | undefined;
  /** Whose a pod session is, as the head marks it. */
  whose?: string | null;
  /** Steering from another device: this computer's offer. */
  remote?: JSX.Element | null;
}): JSX.Element {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const outside = (e: MouseEvent): void => {
      if (!box.current?.contains(e.target as Node)) setOpen(false);
    };
    const escape = (e: KeyboardEvent): void => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", outside);
    document.addEventListener("keydown", escape);
    return () => {
      document.removeEventListener("mousedown", outside);
      document.removeEventListener("keydown", escape);
    };
  }, [open]);
  const role = row?.yourRole;
  const then = (act: () => void) => () => {
    act();
    setOpen(false);
  };

  return (
    <div className="session-menu" ref={box}>
      <button type="button" className="ib" aria-label="More session actions" aria-haspopup="true" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
        ⋯
      </button>
      <div className="menu-pop" hidden={!open} aria-label="This session">
        <button type="button" className="item" aria-pressed={detail !== "quiet"} onClick={then(() => onFold(detail !== "quiet"))}>
          <span className="t">{detail === "quiet" ? "Unfold every turn's working" : "Fold every turn's working"}</span>
          <span className="d">{WORKING_NOW[detail]}</span>
        </button>
        <button type="button" className="item" aria-pressed={backstage} onClick={then(onToggleBackstage)}>
          <span className="t">{backstage ? "Hide backstage" : "Show backstage"}</span>
          <span className="d">Tasks, files, instructions{row && onThisComputer(row.kind) ? ", memory" : ""} and what this session costs</span>
        </button>
        {scratchpad && (
          <button type="button" className="item" aria-pressed={scratchpad.open} onClick={then(scratchpad.onToggle)}>
            <span className="t">{scratchpad.open ? "Hide scratchpad" : "Show scratchpad"}</span>
            <span className="d">What the agents put there with show</span>
          </button>
        )}
        {onAbout && (
          <button type="button" className="item" onClick={then(onAbout)}>
            <span className="t">About the agent</span>
            <span className="d">Open it in the agents manager</span>
          </button>
        )}
        {onRename && (
          <button type="button" className="item" onClick={then(onRename)}>
            <span className="t">Rename session</span>
            <span className="d">The name the session list shows, for everyone who sees it</span>
          </button>
        )}
        {onKeep && (
          <button type="button" className="item" onClick={then(() => onKeep(!row?.pinned))}>
            <span className="t">{row?.pinned ? "Let go from the top" : "Keep at the top"}</span>
            <span className="d">{row?.pinned ? "Back among the rest, by when it was last active" : "Listed first, for everyone who sees it"}</span>
          </button>
        )}
        {sharing && (
          <button type="button" className="item" onClick={then(() => sharing.onShare(sharing.visibility === "team" ? "private" : "team"))}>
            <span className="t">{sharing.visibility === "team" ? "Only me again" : `Give it to ${teamWords(sharing.team)}`}</span>
            <span className="d">{sharing.visibility === "team" ? TAKE_BACK_LINE : giveLine(sharing.team)}</span>
          </button>
        )}
        {living &&
          LIFESPAN_CHOICES.filter((c) => c.value !== living.lifespan).map((c) => (
            <button key={c.value} type="button" className="item" onClick={then(() => living.onRelive(c.value))}>
              <span className="t">{lifespanItem(c.value)}</span>
              <span className="d">{c.sentence}</span>
            </button>
          ))}
        {onSensitive && (
          <button type="button" className="item" onClick={then(onSensitive)}>
            <span className="t">{SENSITIVE_ITEM.title}</span>
            <span className="d">{SENSITIVE_ITEM.line}</span>
          </button>
        )}
        {onArchive && (
          <button type="button" className="item" onClick={then(() => onArchive(!row?.archived))}>
            <span className="t">{archiveItem(Boolean(row?.archived)).title}</span>
            <span className="d">{archiveItem(Boolean(row?.archived)).line}</span>
          </button>
        )}
        {remote && <div className="menu-remote">{remote}</div>}
        <dl className="menu-facts">
          <dt>Session</dt>
          <dd className="mono">{sessionId}</dd>
          {role && (
            <>
              <dt>You</dt>
              <dd>
                you are {role === "owner" ? "the owner" : role === "collaborator" || role === "control" ? "a collaborator" : "a reader"}
              </dd>
            </>
          )}
          {whose && (
            <>
              <dt>Opens</dt>
              <dd>{whose === "the team's" ? "for everyone on its team" : whose === "only you" ? "for only you and the people you invited" : "for its owner and the people they invited"}</dd>
            </>
          )}
          {row?.invitation && (
            <>
              <dt>Invited</dt>
              <dd className="invited-by">{inviteLine(row.invitation)}</dd>
            </>
          )}
        </dl>
      </div>
    </div>
  );
}

/** Up to three rings and a count, with the plain sentence behind them. Your own ring is the dashed one. */
function Here({ members, self }: { members: TranscriptState["presence"]; self: string | undefined }): JSX.Element {
  const names = members.map((m) => (m.subject === self ? "you" : (m.display_name ?? m.subject)));
  const sentence = names.length === 1 ? `${names[0]} is here` : `${names.slice(0, -1).join(", ")} and ${names.at(-1)} are here`;
  return (
    <div className="here" title={sentence} aria-label={sentence}>
      {members.slice(0, 3).map((m) => (
        <span key={m.subject} className={`ring md ${m.subject === self ? "self" : ""}`} style={{ color: personColour(m.subject, self) }} aria-hidden="true">
          {initials(m.display_name ?? m.subject)}
        </span>
      ))}
      <span className="count">{members.length} here</span>
    </div>
  );
}

function Banners({
  status,
  detail,
  dormant,
  readOnly,
  error,
  profile,
}: {
  status: AttachStatus;
  detail: string | null;
  dormant: boolean;
  readOnly: boolean;
  error: string | null;
  /** The plane profile a team session runs on, which a wait for a place names. */
  profile: string | null;
}): JSX.Element | null {
  return (
    <>
      {/* Woken on a full profile, it waits for a place as a new session does. */}
      {status === "waiting" && (
        <div className="banner queued" role="status">
          <p>{profile ? `Waiting for a free place in ${profile}.` : "Waiting for a free place."} It wakes by itself when one frees.</p>
          {detail && <span className="micro">{detail}</span>}
        </div>
      )}
      {dormant && status !== "waiting" && (
        <div className="banner dormant">
          <p>This session is asleep. Reading it does not wake it, and sleeping costs nothing.</p>
        </div>
      )}
      {readOnly && (
        <div className="banner readonly">
          <p>You can read this session but not add to it.</p>
        </div>
      )}
      {(status === "reconnecting" || status === "refreshing") && (
        <div className="banner offline">
          <p>
            Connection lost. Trying again. The work carries on, nothing you have sent is lost, and anything you type now is sent when it
            comes back.
          </p>
          {detail && <span className="micro">{detail}</span>}
        </div>
      )}
      {status === "failed" && (
        <div className="banner error">
          <p>Could not reach this session. {detail ?? ""}</p>
        </div>
      )}
      {error && (
        <div className="banner error">
          <p>{error}</p>
        </div>
      )}
    </>
  );
}

/**
 * What happened here while nobody was reading it (issue #119), as the list's row said it
 * when the session was opened: the only moment it can be read, since opening the session
 * is what clears it. Kept for this visit until it is seen — dismissed, or answered by
 * sending something — and not again, because the daemon has cleared it.
 */
function useAway(sessionId: string, row: FleetRow | undefined): [string | null, () => void] {
  const [away, setAway] = useState<{ id: string; summary: string | null } | null>(null);
  useEffect(() => {
    if (!row || away?.id === sessionId) return;
    setAway({ id: sessionId, summary: unseenSummary(row) });
  }, [sessionId, row, away?.id]);
  const summary = away?.id === sessionId ? away.summary : null;
  return [summary, () => setAway((a) => (a ? { ...a, summary: null } : a))];
}

function Away({ summary, onSeen }: { summary: string; onSeen: () => void }): JSX.Element {
  return (
    <div className="banner away" role="status">
      <p>While you were away: {summary}.</p>
      <button type="button" className="link" onClick={onSeen}>
        Seen
      </button>
    </div>
  );
}

/** `session.loop.get`, once per attachment. It reads the log and wakes nothing. */
function useLoopAnswer(view: SessionHandle["view"]): LoopInfo | null | undefined {
  const [answer, setAnswer] = useState<LoopInfo | null | undefined>(undefined);
  useEffect(() => {
    setAnswer(undefined);
    if (!view) return;
    let live = true;
    view
      .getLoop()
      .then((a) => live && setAnswer(a))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [view]);
  return answer;
}

/** What a turn's foot acts on: its answer's Markdown, and the person's words that began it. */
interface TurnReply {
  answer: string;
  prompt: string | null;
}

/** The kinds that are the troupe speaking or working: drawn beside the mask, as a reply. */
const REPLY_KINDS: ReadonlySet<Entry["kind"]> = new Set(["assistant", "reasoning", "tool", "scratch", "file", "brief", "delegation", "turn"]);

/**
 * The transcript as a chat, in one centred column: a turn's person's words on the right,
 * then the troupe's reply beside the mask — its working folded into the strip, its answer
 * on the page, and under it a row with Copy, Retry, Publish and what the turn cost. What
 * the session says itself (started, switched, compacted) stands between, in mono.
 */
function Stream({
  seed,
  state,
  notes,
  startWords,
  self,
  local,
  detail,
  readBlob,
  onSetup,
  onScratch,
  onSave,
  onRetry,
  onPublish,
  onProposal,
  owner,
  earlier,
  onEarlier,
}: {
  /** What the curtain line's words are taken in the order of, with the turn: the session's id. */
  seed: string;
  /** A page of the history before a checkpoint on its way, or why the last did not come. */
  earlier: SessionHandle["earlier"];
  /** Page in the part before what is drawn. */
  onEarlier: () => Promise<void>;
  state: TranscriptState;
  /** This app's own lines, each after the event it was said at. */
  notes: Note[];
  /** The start's `onboarding_suggested` at `seq` in this app's words; a null text keeps the harness's. */
  startWords?: { seq: number; text: string | null } | undefined;
  self: string | undefined;
  /** A session on this computer, whose model settings are this person's to change. */
  local: boolean;
  /** How much of each turn is open. */
  detail: Detail;
  readBlob: (blob: string) => Promise<string>;
  /** Leave for the Setup screen, offered under a model error a first run can fix. */
  onSetup?: (() => void) | undefined;
  /** Open the scratchpad on a document, by name. */
  onScratch: (name: string) => void;
  /** Save a file the agent made, by its path in the session's workspace: what was said of it. */
  onSave: (path: string) => Promise<string>;
  /** Send the person's words again as a new turn; absent where they may only read, or why not where the session takes no more. */
  onRetry?: ((text: string) => Promise<void>) | string | undefined;
  /** Open the publish dialog with a reply as its file; absent with no daemon to publish through. */
  onPublish?: ((text: string) => void) | undefined;
  /** What the session's owner may do with what the harness proposed. */
  onProposal?: ProposalActions | undefined;
  /** Whether this person is the session's owner. */
  owner?: boolean | undefined;
}): JSX.Element {
  // The turns a click on their strip opened (or shut, at `everything`), by key. Another
  // level draws every turn again, all of them as it says.
  const [opened, setOpened] = useState<ReadonlySet<string>>(new Set());
  useEffect(() => setOpened(new Set()), [detail]);
  const toggle = useCallback(
    (turn: string): void =>
      setOpened((was) => {
        const next = new Set(was);
        if (!next.delete(turn)) next.add(turn);
        return next;
      }),
    [],
  );

  // The clock, while something runs: a running call's strip and the curtain line count from it.
  const now = useNow(isBusy(state) || needsYou(state));
  // Each turn is laid out again only when it changed, or while a call of it runs and the
  // clock moves, so a tick draws the strip that counts and the curtain line, and no turn
  // else (`TurnGroup` below hands React the same props for the rest).
  const laid = useRef<LayoutCache>(new Map());
  const drawn = useMemo(() => layout(state.entries, { detail, opened, now }, laid.current), [state.entries, detail, opened, now]);
  // What streams belongs to the last turn, and is drawn at its level.
  const live = drawn.at(-1)?.level ?? detail;
  const line = curtainLine(state, now, seed);
  const replies = useMemo(() => repliesOf(drawn, self), [drawn, self]);
  // Where two or more people steer, an answered question names who answered it.
  const several = severalSteer(state, self);

  const bottom = useRef<HTMLDivElement>(null);
  // What the session adds goes at the bottom; a page of its history drawn above is not that.
  const tail = state.entries.length - (state.earlier?.drawn ?? 0);
  useEffect(() => {
    // Scrolling is not focus: an arriving event must never move the caret.
    bottom.current?.scrollIntoView({ block: "end" });
  }, [tail, state.streaming, state.pending.length, notes.length, state.thinking === "", line === null]);

  // A page of history goes in above what is on screen, which stays where it was.
  const stream = useRef<HTMLDivElement>(null);
  const place = useRef<(() => void) | null>(null);
  useLayoutEffect(() => {
    place.current?.();
    place.current = null;
  }, [state.earlier?.from]);
  const pageBack = (): void => {
    place.current = holdPlace(stream.current);
    void onEarlier();
  };

  // The turns as the chat draws them: the person's line that began each, then the rest.
  const groups: Group[] = [];
  drawn.forEach((d, i) => {
    const next = drawn[i + 1]?.entry.seq ?? Infinity;
    const group = groups.at(-1);
    if (!group || group.turn !== d.turn) {
      const opens = d.entry.kind === "user" && isRoot(d.entry.agent);
      groups.push({ turn: d.turn, person: opens ? d : null, rest: opens ? [] : [{ d, next }] });
      if (opens) groups.at(-1)!.rest.push({ d: drawnAside(d), next });
    } else group.rest.push({ d, next });
  });

  // What is under way now, in the last reply: reasoning as it comes, the answer as it is
  // written, and the line that says what runs.
  const working = Boolean((state.thinking && live !== "quiet") || state.streaming || line);
  const liveParts = working ? (
    <>
      {state.thinking && live !== "quiet" && (
        <ReasoningFrame text={state.thinking} ms={state.thinkingAt === undefined ? undefined : now - state.thinkingAt} open={live === "everything"} />
      )}
      {state.streaming && (
        <article className="turn agent">
          <div className="frame prose">
            <div className="md caret">{state.streaming}</div>
          </div>
        </article>
      )}
      {line && <Curtain line={line} />}
    </>
  ) : null;
  // The last turn is still being answered while it has not said what it cost.
  const lastOpen = drawn.at(-1)?.entry.kind !== "turn";

  return (
    <div className="stream" aria-live="polite" ref={stream}>
      {state.entries.length === 0 && <Loading what="Reading the session. The newest part arrives first." />}
      {state.earlier?.more && (
        <p className="note earlier-more">
          <button type="button" className="link" disabled={earlier.loading} onClick={pageBack}>
            Earlier
          </button>{" "}
          {earlier.loading
            ? "Reading the part before this."
            : earlier.error
              ? `The part before this could not be read: ${earlier.error}`
              : "What came before this, as it happened."}
        </p>
      )}
      {state.entries[0]?.seq === 1 && (
        <div className="divider" aria-hidden="true">
          {curtainUp(state.startedAt)}
        </div>
      )}

      <NotesAt notes={notes} from={-Infinity} to={state.entries[0]?.seq ?? Infinity} />
      {groups.map((g, gi) => {
        const last = gi === groups.length - 1;
        const reply = replies.get(g.turn);
        return (
          <TurnGroup
            key={g.turn}
            group={g}
            working={last && working}
            liveParts={last && lastOpen ? liveParts : null}
            startWords={startWords}
            notes={notes}
            reply={reply}
            self={self}
            several={several}
            local={local}
            readBlob={readBlob}
            onSetup={onSetup}
            onScratch={onScratch}
            onSave={onSave}
            onRetry={onRetry}
            onPublish={onPublish}
            onProposal={onProposal}
            owner={owner}
            onToggle={toggle}
          />
        );
      })}
      {/* Under way with nothing of the turn drawn yet, or after a turn that said its cost. */}
      {working && (groups.length === 0 || !lastOpen) && (
        <div className="reply">
          <span className="avatar" aria-hidden="true">
            <Mask size={20} />
          </span>
          <div className="reply-body">
            <span className="who">Troupe</span>
            {liveParts}
          </div>
        </div>
      )}

      {/* Queued, not optimistic: it is not in the stream until the server says it is. */}
      {state.pending.map((p) => (
        <article key={p.commandId} className="turn person self queued">
          <div className="byline">
            <Pill status="queued">{p.queued ? "Queued" : "Sending"}</Pill>
          </div>
          <div className="body">{p.text}</div>
        </article>
      ))}

      <div ref={bottom} />
    </div>
  );
}

// The person's line that began a turn, drawn on its own, stands in the reply only for the
// notes said after it: the same object for the same line, so the turn is not drawn anew.
const asides = new WeakMap<Drawn, Drawn>();
function drawnAside(d: Drawn): Drawn {
  const kept = asides.get(d);
  if (kept) return kept;
  const aside = { ...d, hidden: true, strip: null };
  asides.set(d, aside);
  return aside;
}

/** A turn as the chat draws it: the person's line that began it, then the rest, each with the seq after it. */
interface Group {
  turn: string;
  person: Drawn | null;
  rest: Array<{ d: Drawn; next: number }>;
}

type GroupProps = Omit<EntryProps, "drawn" | "words" | "reply"> & {
  group: Group;
  /** The last turn while something is under way: drawn as a reply, with `liveParts` in it. */
  working: boolean;
  liveParts: ReactNode;
  startWords?: { seq: number; text: string | null } | undefined;
  notes: Note[];
  reply: TurnReply | undefined;
  onToggle: (turn: string) => void;
};

/**
 * Whether a turn would draw the same: its laid-out entries are the same objects (`layout`
 * hands them back for a turn nothing changed), and so is everything else it is given. The
 * clock's tick and a page of history drawn above leave every other turn as it was.
 */
function sameGroup(a: GroupProps, b: GroupProps): boolean {
  for (const key of Object.keys(a) as Array<keyof GroupProps>) {
    if (key === "group") {
      const [x, y] = [a.group, b.group];
      if (x.turn !== y.turn || x.person !== y.person || x.rest.length !== y.rest.length) return false;
      if (!x.rest.every((r, i) => r.d === y.rest[i]!.d && r.next === y.rest[i]!.next)) return false;
    } else if (key === "reply") {
      if (a.reply?.answer !== b.reply?.answer || a.reply?.prompt !== b.reply?.prompt) return false;
    } else if (key === "startWords") {
      if (a.startWords?.seq !== b.startWords?.seq || a.startWords?.text !== b.startWords?.text) return false;
    } else if (a[key] !== b[key]) return false;
  }
  return Object.keys(a).length === Object.keys(b).length;
}

const TurnGroup = memo(function TurnGroup({ group: g, working, liveParts, startWords, notes, reply, onToggle, ...entry }: GroupProps): JSX.Element {
  const entryOf = ({ d, next }: { d: Drawn; next: number }): JSX.Element => (
    <Fragment key={`${d.entry.kind}-${d.entry.seq}`}>
      {d.strip && <StripLine strip={d.strip} onToggle={() => onToggle(d.turn)} />}
      {!d.hidden && (
        <StreamEntry
          drawn={d}
          words={startWords && startWords.seq === d.entry.seq ? startWords.text : null}
          {...entry}
          reply={d.entry.kind === "turn" ? reply : undefined}
        />
      )}
      <NotesAt notes={notes} from={d.entry.seq} to={next} />
    </Fragment>
  );
  // A reply is the troupe's part of a turn; the session's own lines stand on their own.
  const isReply = g.rest.some(({ d }) => REPLY_KINDS.has(d.entry.kind) && !(d.hidden && d.entry.kind === "user")) || working;
  return (
    <>
      {g.person && <StreamEntry drawn={g.person} words={null} self={entry.self} local={entry.local} readBlob={entry.readBlob} onScratch={entry.onScratch} onSave={entry.onSave} />}
      {isReply ? (
        <div className="reply">
          <span className="avatar" aria-hidden="true">
            <Mask size={20} />
          </span>
          <div className="reply-body">
            <span className="who">Troupe</span>
            {g.rest.map(entryOf)}
            {liveParts}
          </div>
        </div>
      ) : (
        g.rest.map(entryOf)
      )}
    </>
  );
}, sameGroup);

/**
 * Each turn's answer and the person's words that began it, by turn: what its foot's Copy,
 * Publish and Retry act on. The answer is the root's prose after its last call, or its last
 * prose where it made none; the words are the person's own, not somebody else's.
 */
function repliesOf(drawn: Drawn[], self: string | undefined): Map<string, TurnReply> {
  const acc = new Map<string, { answer: string; answered: boolean; prompt: string | null }>();
  for (const d of drawn) {
    const had = acc.get(d.turn) ?? { answer: "", answered: false, prompt: null };
    const e = d.entry;
    if (e.kind === "user" && isRoot(e.agent) && had.prompt === null && (e.author === undefined || e.author === self)) had.prompt = e.text;
    else if (e.kind === "assistant" && isRoot(e.agent)) {
      if (d.role === "answer") {
        had.answer = had.answered ? `${had.answer}\n\n${e.text}` : e.text;
        had.answered = true;
      } else if (!had.answered) had.answer = e.text;
    }
    acc.set(d.turn, had);
  }
  return new Map([...acc].map(([turn, r]) => [turn, { answer: r.answer, prompt: r.prompt }]));
}
/**
 * A file the agent made for the person (troupe #765): its path, where it already is when the
 * session runs on this computer, and a Save… that reads it with `fs.read` from wherever the
 * session runs and puts it where the person chooses. What happened is said on the line.
 */
function FileReady({ entry, onSave }: { entry: Extract<Entry, { kind: "file" }>; onSave: (path: string) => Promise<string> }): JSX.Element {
  const [said, setSaid] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const save = async (): Promise<void> => {
    setSaving(true);
    try {
      setSaid(await onSave(entry.path));
    } finally {
      setSaving(false);
    }
  };
  return (
    <p className="note file-ready">
      File ready: <code>{entry.localPath ?? entry.path}</code>{" "}
      <button className="link" disabled={saving} onClick={() => void save()}>
        Save…
      </button>
      {said && <span className="micro muted"> {said}</span>}
    </p>
  );
}

/** This app's lines said at or after `from` and before `to`. */
function NotesAt({ notes, from, to }: { notes: Note[]; from: number; to: number }): JSX.Element | null {
  const here = notes.filter((n) => n.after >= from && n.after < to);
  if (here.length === 0) return null;
  return (
    <>
      {here.map((n, i) => (
        <p key={`${n.after}-${i}-${n.text}`} className="note start-note">
          {n.text}
        </p>
      ))}
    </>
  );
}

type EntryProps = {
  /** The entry, with the level it is drawn at. */
  drawn: Drawn;
  /** What this app says for the entry instead of its text, where it words it itself. */
  words: string | null;
  self: string | undefined;
  /** Two or more people steer the session, so an answer says whose it was. */
  several?: boolean;
  local: boolean;
  readBlob: (blob: string) => Promise<string>;
  onSetup?: (() => void) | undefined;
  onScratch: (name: string) => void;
  onSave: (path: string) => Promise<string>;
  /** For the line that says what a turn cost: what its foot acts on. */
  reply?: TurnReply | undefined;
  onRetry?: ((text: string) => Promise<void>) | string | undefined;
  onPublish?: ((text: string) => void) | undefined;
  /** What the session's owner may do with what the harness proposed; absent for anybody else. */
  onProposal?: ProposalActions | undefined;
  /** Whether this person is the session's owner, who alone answers a proposal. */
  owner?: boolean | undefined;
};

/**
 * Whether an entry would draw the same: the fold hands back the same object for an entry
 * nothing changed, so the clock that ticks while a turn runs redraws the strip and the
 * curtain line, not the whole transcript.
 */
function sameEntry(a: EntryProps, b: EntryProps): boolean {
  return (
    a.drawn.entry === b.drawn.entry &&
    a.drawn.level === b.drawn.level &&
    a.words === b.words &&
    a.self === b.self &&
    a.several === b.several &&
    a.local === b.local &&
    a.readBlob === b.readBlob &&
    a.onSetup === b.onSetup &&
    a.onScratch === b.onScratch &&
    a.onSave === b.onSave &&
    a.reply?.answer === b.reply?.answer &&
    a.reply?.prompt === b.reply?.prompt &&
    a.onRetry === b.onRetry &&
    a.onPublish === b.onPublish &&
    a.onProposal === b.onProposal &&
    a.owner === b.owner
  );
}

const StreamEntry = memo(function StreamEntry({
  drawn,
  words,
  self,
  several = false,
  local,
  readBlob,
  onSetup,
  onScratch,
  onSave,
  reply,
  onRetry,
  onPublish,
  onProposal,
  owner = false,
}: EntryProps): JSX.Element | null {
  const { entry, level } = drawn;
  switch (entry.kind) {
    case "user": {
      const mine = entry.author === self || entry.author === undefined;
      // Another person by their name where the event carries one, and their subject where not.
      const name = mine ? "You" : (entry.authorName ?? entry.author ?? entry.source);
      // A person's words on the right; your own need no name, somebody else's carry theirs.
      const said = [mine ? null : name, entry.source !== "user" ? `via ${entry.source}` : null, entry.via === "plane" ? "from another device" : null].filter(Boolean);
      return (
        <article className={`turn person ${mine ? "self" : ""}`} style={{ ["--author" as string]: personColour(entry.author, self) }}>
          {said.length > 0 && (
            <div className="byline">
              {!mine && (
                <span className="ring" aria-hidden="true">
                  {initials(name)}
                </span>
              )}
              {!mine && <span className="name">{name}</span>}
              {entry.source !== "user" && <span className="micro muted">via {entry.source}</span>}
              {entry.via === "plane" && <span className="micro muted">from another device</span>}
            </div>
          )}
          <div className="body">{entry.text}</div>
        </article>
      );
    }

    // The model's prose, on the rendered surface: a block inside it is cut past the cap
    // unless the turn is drawn at everything; the prose around it never is.
    case "assistant":
      return (
        <article className="turn agent">
          {entry.agent.length > 1 && (
            <div className="byline">
              <span className="micro muted">{entry.agent.slice(1).join(" › ")}</span>
            </div>
          )}
          <ProseFrame text={entry.text} full={level === "everything"} />
        </article>
      );

    case "reasoning":
      return <ReasoningFrame text={entry.text} ms={entry.ms} open={level === "everything"} />;

    case "tool":
      return <ToolFrame entry={entry} level={level} readBlob={readBlob} />;

    case "scratch":
      return <ScratchCard entry={entry} onOpen={onScratch} />;

    case "file":
      return <FileReady entry={entry} onSave={onSave} />;

    // A subagent's first message is the brief it was handed: from the agent that delegated,
    // never a person's turn, its parts under their names (troupe Decision 852). A brief
    // from before the parts is the text it was.
    case "brief":
      return (
        <article className="turn brief" aria-label={`The brief ${entry.child} was handed`}>
          <div className="byline">
            <span className="name">Brief</span>
            <span className="micro muted">
              from {entry.from.length > 1 ? entry.from.slice(1).join(" › ") : "the session's agent"} to {entry.agent.slice(1).join(" › ")}
            </span>
          </div>
          {entry.parts.length > 0 ? (
            <dl className="facts wide parts">
              {entry.parts.map(([name, text]) => (
                <Fragment key={name}>
                  <dt>{name.replace("_", " ")}</dt>
                  <dd>{text}</dd>
                </Fragment>
              ))}
            </dl>
          ) : (
            <div className="body">{entry.text}</div>
          )}
        </article>
      );

    // The brief's goal says what it is for in a line; the parts are in the delegate call's.
    // One in the background says so: its call answered at once (troupe Decision 853).
    case "delegation":
      return (
        <p className="note">
          Handed to {entry.child}
          {entry.background ? ", in the background" : ""}: {entry.brief.find(([name]) => name === "goal")?.[1] ?? entry.task}
        </p>
      );

    // The task list lives in the backstage; each update in the stream would be noise.
    case "todo":
      return null;

    // A transcript opened from a checkpoint begins with what the compaction said of the
    // part before it, as a quote; Earlier, above, reads that part as it happened.
    case "earlier":
      return (
        <section className="earlier" aria-label="Earlier in this session, in short">
          <p className="note">
            Earlier{entry.at ? `, summarised ${remoteWhen(entry.at)}` : ""}
          </p>
          {entry.summary ? (
            <blockquote className="earlier-summary">
              <Markdown text={entry.summary} full={level === "everything"} />
            </blockquote>
          ) : (
            <p className="note">The session summarised what came before this.</p>
          )}
        </section>
      );

    case "approval":
      return entry.decision ? <DecisionRecord entry={entry} self={self} /> : null;

    case "question":
      return entry.answer === undefined ? null : <AnswerRecord entry={entry} self={self} several={several} />;

    // What the harness offers the owner, where the turn that earned it ended: theirs to
    // answer, and a line for everybody else.
    case "proposal":
      return <ProposalCard entry={entry} mine={owner} actions={onProposal} />;

    // What the turn cost, under it, in the client library's words (issue #389). A
    // subagent's says whose it is, as its answers do.
    case "turn": {
      const cost = (
        <p className="note turn-cost">
          {entry.agent.length > 1 && `${entry.agent.slice(1).join(" › ")} · `}
          {entry.text}
        </p>
      );
      // A subagent's line is its own; the root's ends the reply, with what can be done with it.
      return entry.agent.length > 1 ? cost : <ReplyFoot reply={reply} onRetry={onRetry} onPublish={onPublish} cost={cost} />;
    }

    case "system": {
      const step = local && entry.type === "llm_error" ? modelErrorStep(entry.text) : null;
      return (
        <>
          <p
            className={`note ${ERROR_NOTES.has(entry.type) ? "error" : ""} ${entry.type === "profile_switched" ? "switched" : ""} ${entry.type === "session_marked_sensitive" ? "sensitive" : ""}`}
          >
            {/* The start's suggestion is the harness's sentence, written for a terminal in
                Markdown: in this app's words where it has them, else rendered, never raw. */}
            {entry.type === "onboarding_suggested" ? (words ?? <InlineMarkdown text={entry.text} />) : entry.text}
          </p>
          {step && (
            <p className="note">
              {step}
              {/* The first run's questions fix both, one step at a time (Decision 705). */}
              {onSetup && (
                <>
                  {" "}
                  <button type="button" className="link" onClick={onSetup}>
                    Run setup
                  </button>
                </>
              )}
            </p>
          )}
        </>
      );
    }
  }
}, sameEntry);

/**
 * What a person does about a failed model request in a session on this computer, where
 * there is one obvious thing. A computer with no model settings is the commonest first
 * run, and its first request fails with "no API key is configured"; the settings are on
 * This computer, under Models. A team session's model is the plane's, not this person's
 * to set, so it gets no step. The terminal client puts its own step under the same two
 * errors (`Troupe.UI.ModelError`).
 */
function modelErrorStep(text: string): string | null {
  const reason = text.replace(/^model error: /, "");
  if (reason.startsWith("no API key is configured")) return "Set up a provider on This computer, under Models.";
  if (reason.startsWith("the provider rejected the credentials")) return "Check the key on This computer, under Models.";
  return null;
}

/**
 * A document an agent put in the scratchpad with `show` (issue #472), where its call would
 * be: the title, then the name, the size and which write of the name it was, and a press
 * opens it in the scratchpad beside the conversation. Its text is never in the stream. A
 * call that failed says why, and there is nothing to open.
 */
function ScratchCard({ entry, onOpen }: { entry: Extract<Entry, { kind: "scratch" }>; onOpen: (name: string) => void }): JSX.Element {
  if (entry.ok === false) {
    return (
      <p className="note error">
        Could not show {entry.name || "a document"}: {entry.error ?? "the call failed"}
      </p>
    );
  }
  const facts = [entry.name, entry.size === undefined ? undefined : bytes(entry.size), scratchVersion(entry.version)].filter(Boolean);
  return (
    <button type="button" className="scratch-card" disabled={!entry.name} onClick={() => onOpen(entry.name)} title="Open it in the scratchpad">
      <span className="title">{entry.title || entry.name || "A document"}</span>
      <span className="meta">{facts.join(" · ")}</span>
    </button>
  );
}

/** The document written last, which the header's switch opens the scratchpad on. */
function latest(docs: ScratchDocument[]): string | null {
  return docs.reduce<ScratchDocument | null>((last, d) => (!last || d.updated_at >= last.updated_at ? d : last), null)?.name ?? null;
}

/**
 * The session's scratchpad (issue #472): a tab for each document, in the order each was
 * first written, and the open one's text, read when its tab opens and again when a newer
 * version of it is written. A markdown document is rendered as an answer is, with its
 * source a toggle away; the other kinds are shown as they were written (a `mermaid`
 * document as its source, for now). Read-only, like the session's files.
 */
function Scratchpad({
  view,
  docs,
  open,
  onOpen,
  onClose,
}: {
  view: SessionView | null;
  docs: ScratchDocument[];
  /** The open document's name. */
  open: string;
  onOpen: (name: string) => void;
  onClose: () => void;
}): JSX.Element {
  const doc = docs.find((d) => d.name === open);
  const read = useScratchText(view, doc);
  return (
    <aside className="scratchpad" aria-label="Scratchpad">
      <header>
        <span className="screen">Scratchpad</span>
        <div className="tabs" role="tablist">
          {docs.map((d) => (
            <button key={d.name} type="button" role="tab" className="tab" aria-selected={d.name === open} title={d.title} onClick={() => onOpen(d.name)}>
              {d.name}
            </button>
          ))}
        </div>
        <button type="button" className="link" onClick={onClose}>
          Close
        </button>
      </header>
      {doc ? (
        <div className="doc" role="tabpanel">
          <h3>{doc.title}</h3>
          <p className="note">{[doc.name, bytes(doc.size), scratchVersion(doc.version)].join(" · ")}</p>
          {read.error ? (
            <p className="note error">{read.error}</p>
          ) : read.content === null ? (
            <Loading what="Reading the document…" />
          ) : doc.kind === "markdown" ? (
            // A prose frame, as an answer is, and whole: the scratchpad is where a long
            // document is read.
            <ProseFrame text={read.content} full />
          ) : (
            <pre className="payload">{read.content}</pre>
          )}
        </div>
      ) : (
        <p className="note doc">Nothing is written under {open} yet.</p>
      )}
    </aside>
  );
}

/**
 * A scratchpad document's text, read with `fs.read` when it is opened and again for each
 * newer version. What an older version said stays on screen until the newer one is read.
 */
function useScratchText(view: SessionView | null, doc: ScratchDocument | undefined): { content: string | null; error: string | null } {
  const [read, setRead] = useState<{ name: string; content: string | null; error: string | null } | null>(null);
  const name = doc?.name;
  const path = doc?.path;
  const version = doc?.version;
  useEffect(() => {
    if (!view || !name || !path) return;
    let live = true;
    view
      .scratchRead({ path })
      .then((file) => live && setRead({ name, content: file.content, error: null }))
      .catch((e: unknown) => live && setRead({ name, content: null, error: errorText(e) }));
    return () => {
      live = false;
    };
  }, [view, name, path, version]);
  return read && read.name === name ? read : { content: null, error: null };
}

/** A pod session's repositories as Backstage says them, with Attach and Take off for its owner. */
interface RepositoriesPanel {
  held: SessionRepository[];
  listed: string[];
  owner: boolean;
  onAttach?: ((r: ChosenRepository) => Promise<string | null>) | undefined;
  onTakeOff?: ((name: string) => Promise<string | null>) | undefined;
}

/** A pod session's configuration as the panel says it, with Update for its owner. */
interface Configuration {
  version: number;
  current: number | null;
  /** A raise the plane keeps for the agent's rest. */
  owed: number | null;
  busy: boolean;
  onUpdate?: (() => Promise<void>) | undefined;
}

function Backstage({
  view,
  daemon,
  row,
  configuration,
  repositories,
  onEditTodo,
  self,
  selfName,
  pane,
  onPane,
  onClose,
  memory,
  onOpenMemory,
  onProfile,
}: {
  view: SessionHandle;
  daemon: DaemonClient | null;
  row: FleetRow | undefined;
  /** A pod session's bundle version and its channel's current one; absent elsewhere. */
  configuration?: Configuration | undefined;
  /** A pod session's GitHub repositories; absent elsewhere. */
  repositories?: RepositoriesPanel | undefined;
  /** Change the task list (`todo.edit`); absent where the person may only read the session. */
  onEditTodo?: TodoEdit | undefined;
  self: string | undefined;
  /** The signed-in person's name, where the plane knows one; undefined signed out. */
  selfName?: string | undefined;
  /** Which pane is up: the session's, so `/files` and `/memory` from the palette can open it. */
  pane: Pane;
  onPane: (pane: Pane) => void;
  /** Hide it again, as the head's ⋯ does. */
  onClose: () => void;
  /**
   * What the memory pane needs: a session on this computer's daemon, workspace, id and the
   * librarian its start began; null for a team session's.
   */
  memory: {
    daemon: DaemonClient;
    workspace: string | undefined;
    sessionId: string;
    librarians: string[];
    ask: MemoryAsk | null;
    onAsked: () => void;
  } | null;
  /** The app's Memory view, where the person's own memory is read and changed. */
  onOpenMemory?: (() => void) | undefined;
  /** The page of what the session's plane profile gives a session. */
  onProfile?: ((name: string) => void) | undefined;
}): JSX.Element {
  const agents = Object.entries(view.state.agentState).filter(([path]) => path !== "");
  // A team session's memory is its pod's, and `memory.get` is this computer's daemon's; a
  // local session's settings are this computer's, which its settings screens show.
  const team = row?.kind === "team";
  // The plane profile a team session runs on, whose page says what it gives a session.
  const onPlane = team ? (row?.profile ?? null) : null;
  const shown: Pane = (pane === "memory" && !memory) || (pane === "settings" && !team) ? "tasks" : pane;

  return (
    <aside className="backstage" aria-label="Backstage">
      <section>
        <div className="backstage-head">
          <span className="screen">Backstage</span>
          <button type="button" className="link" onClick={onClose}>
            Close
          </button>
        </div>
        <div className="tabs">
          <button className="tab" aria-selected={shown === "tasks"} onClick={() => onPane("tasks")}>
            Tasks
          </button>
          <button className="tab" aria-selected={shown === "files"} onClick={() => onPane("files")}>
            Files
          </button>
          <button className="tab" aria-selected={shown === "instructions"} onClick={() => onPane("instructions")}>
            Instructions
          </button>
          {memory && (
            <button className="tab" aria-selected={shown === "memory"} onClick={() => onPane("memory")}>
              Memory
            </button>
          )}
          {team && (
            <button className="tab" aria-selected={shown === "settings"} onClick={() => onPane("settings")}>
              Settings
            </button>
          )}
        </div>
      </section>

      {shown === "settings" ? (
        <section>
          <h3>Settings</h3>
          {onPlane && (
            <p className="note">
              On <span className="mono">{onPlane}</span>
              {onProfile && (
                <button className="link profile-link" onClick={() => onProfile(onPlane)}>
                  What this profile can reach
                </button>
              )}
            </p>
          )}
          <PodConfig view={view.view} />
        </section>
      ) : shown === "instructions" ? (
        <section>
          <h3>Instructions</h3>
          <Instructions view={view.view} daemon={team ? null : daemon} onOpenMemory={onOpenMemory} />
        </section>
      ) : shown === "memory" && memory ? (
        <section>
          <h3>Memory</h3>
          <MemoryPane
            daemon={memory.daemon}
            workspace={memory.workspace}
            sessionId={memory.sessionId}
            librarians={memory.librarians}
            ask={memory.ask}
            onAsked={memory.onAsked}
          />
        </section>
      ) : shown === "tasks" ? (
        <section>
          <h3>Running order</h3>
          <Tasks todo={view.state.todo} onEdit={onEditTodo} />
        </section>
      ) : (
        <section>
          <h3>Files</h3>
          <Files view={view.view} />
        </section>
      )}

      {agents.length > 0 && (
        <section>
          <h3>The company</h3>
          <ul className="cast">
            {agents.map(([path, state]) => (
              <li key={path}>
                <span className="mono">{path}</span>
                <span className="state">{state}</span>
              </li>
            ))}
          </ul>
        </section>
      )}

      {daemon && row && onThisComputer(row.kind) && <LocalControls daemon={daemon} row={row} session={view.view} />}

      <section>
        <h3>This session</h3>
        <dl className="facts">
          <dt>Cost so far</dt>
          <dd>
            <Cost micros={view.state.costMicros ?? row?.costMicros} />
          </dd>
          <dt>Started</dt>
          <dd>
            <When iso={row?.lastActiveAt ?? null} />
          </dd>
          <dt>Owner</dt>
          {/* A session on this computer with no owner on record is this computer's user's,
              which is the person looking at it: by the name they are signed in under where
              there is one, as the platform's rows name a person, and "you" signed out. */}
          <dd>
            {row && onThisComputer(row.kind) && (!row.owner || row.owner === self)
              ? (selfName ?? "you")
              : row?.owner === self
                ? "you"
                : row?.owner
                  ? nameOrSubject(row.owner, row.ownerName)
                  : "—"}
          </dd>
          {/* The bundle is what the platform loaded the session's agents from: a session on
              this computer has none, so it has no row rather than a dash. Behind its
              channel, its owner updates it: now at rest, else when the agent is done. */}
          {configuration ? (
            <>
              <dt>Configuration</dt>
              <dd>
                {configurationLine(configuration.version, configuration.current)}
                {configuration.owed !== null ? (
                  <span className="muted"> · {owedLine(configuration.owed)}</span>
                ) : configuration.onUpdate && configuration.current !== null && behind(configuration.version, configuration.current) ? (
                  <>
                    {" "}
                    <button
                      type="button"
                      className="link"
                      title={updateLine(configuration.current, configuration.busy)}
                      onClick={() => void configuration.onUpdate?.()}
                    >
                      {configuration.busy ? "Update when the agent is done" : "Update"}
                    </button>
                  </>
                ) : null}
              </dd>
            </>
          ) : (
            view.state.bundleVersion &&
            !(row && onThisComputer(row.kind)) && (
              <>
                <dt>Configuration</dt>
                <dd>v{view.state.bundleVersion}</dd>
              </>
            )
          )}
        </dl>
      </section>

      {repositories && (
        <SessionRepositories
          repositories={repositories.held}
          listed={repositories.listed}
          owner={repositories.owner}
          onAttach={repositories.onAttach}
          onTakeOff={repositories.onTakeOff}
        />
      )}
    </aside>
  );
}

/**
 * Under a reply, on hover or focus: Copy (the answer's Markdown), Retry (the person's words
 * again, as a new turn), Publish (the publish dialog, with the answer as its file), and what
 * the turn cost. Retry and Publish say why where they cannot.
 */
function ReplyFoot({
  reply,
  onRetry,
  onPublish,
  cost,
}: {
  reply: TurnReply | undefined;
  onRetry?: ((text: string) => Promise<void>) | string | undefined;
  onPublish?: ((text: string) => void) | undefined;
  cost: JSX.Element;
}): JSX.Element {
  const [said, setSaid] = useState<string | null>(null);
  const answer = reply?.answer ?? "";
  const prompt = reply?.prompt ?? null;
  const act = (what: () => Promise<unknown>, done: string): void => {
    what().then(
      () => setSaid(done),
      (e: unknown) => setSaid(errorText(e)),
    );
  };
  return (
    <div className="foot">
      <button type="button" className="fbtn" disabled={!answer} title={answer ? "Copy the answer as Markdown" : "This turn has no answer to copy"} onClick={() => act(() => copyText(answer), "copied")}>
        Copy
      </button>
      <button
        type="button"
        className="fbtn"
        disabled={typeof onRetry !== "function" || prompt === null}
        title={
          typeof onRetry === "string"
            ? onRetry
            : !onRetry
            ? "You can read this session but not add to it"
            : prompt === null
              ? "Not yet: the transcript does not say which message of yours began this turn"
              : "Send your message again, as a new turn"
        }
        onClick={() => prompt !== null && typeof onRetry === "function" && act(() => onRetry(prompt), "sent again")}
      >
        Retry
      </button>
      <button
        type="button"
        className="fbtn"
        disabled={!onPublish || !answer}
        title={!onPublish ? "Publishing goes through this computer's daemon, and there is none here" : "Publish the answer as an artifact"}
        onClick={() => onPublish?.(answer)}
      >
        Publish
      </button>
      {cost}
      {said && (
        <span className="micro muted" role="status">
          {said}
        </span>
      )}
    </div>
  );
}

/** A file, an artifact's file or a folder, attached to the message being written. */
interface Attachment {
  id: string;
  /** `artifact`: one the server puts into the workspace itself, fetching it from the plane (troupe #920). */
  kind: "file" | "folder" | "artifact";
  /** The name it lands under, `session:/<name>`, the folder's path, or the artifact's title. */
  name: string;
  /** Its text, for a file. */
  content?: string;
  /** The artifact and its version, for an `artifact`. */
  artifact?: { id: string; version: number | undefined };
  /** What it is, in a few words: its size, or the artifact it came from. */
  about: string;
}

let attached = 0;

/** A token count as the ring says it: `24.1k`. */
function tokens(n: number): string {
  return n >= 1000 ? `${(n / 1000).toFixed(1).replace(/\.0$/, "")}k` : String(n);
}

/**
 * A picked or dropped file as text: an upload carries text only, as the terminal client's
 * `/upload` does, and one larger than the server takes in a message is refused unread.
 */
async function readAttachment(file: File, max: number | undefined): Promise<Attachment> {
  // What a message carries around the file, kept clear of the server's limit.
  if (max !== undefined && file.size > max - 4096) throw new Error(`${file.name} is larger than this session takes in one message (${bytes(max)})`);
  let content: string;
  try {
    content = new TextDecoder("utf-8", { fatal: true }).decode(await file.arrayBuffer());
  } catch {
    throw new Error(`${file.name} is not UTF-8 text; an upload carries text only`);
  }
  return { id: `a${++attached}`, kind: "file", name: baseName(file.name), content, about: bytes(file.size) };
}

function baseName(path: string): string {
  return path.split(/[\\/]/).pop() || path;
}

/**
 * How full the context is, as a ring by the send button. With the window the harness plans
 * compaction against (a `context_status` event, troupe #920) it is the share used; until a
 * server sends that, an indeterminate arc whose label says the tokens in it and that the
 * window is not reported.
 */
export function ContextRing({ fill }: { fill: ContextFill | undefined }): JSX.Element {
  const r = 11;
  const c = 2 * Math.PI * r;
  const share = fill?.window ? Math.min(1, fill.used / fill.window) : null;
  const label =
    share !== null && fill
      ? `Context ${Math.round(share * 100)}% full: ${tokens(fill.used)} of ${tokens(fill.window!)} tokens`
      : fill
        ? `Context: ${tokens(fill.used)} tokens in; the window size is not reported yet.`
        : "Context: nothing sent yet; the window size is not reported yet.";
  return (
    <span className={`ring-context${share === null ? " unknown" : share > 0.8 ? " full" : ""}`} role="img" aria-label={label} title={label}>
      <svg width="26" height="26" viewBox="0 0 26 26" aria-hidden="true">
        <circle cx="13" cy="13" r={r} className="track" />
        <circle cx="13" cy="13" r={r} className="arc" strokeDasharray={`${(c * (share ?? 0.25)).toFixed(1)} ${c.toFixed(1)}`} transform="rotate(-90 13 13)" />
      </svg>
    </span>
  );
}

/**
 * The person's artifacts on the plane, to attach one's files to the message. Where the
 * session's server takes `fs.upload` with `artifact` (`UPLOAD_ARTIFACT`, troupe #920) the
 * artifact itself is attached, and the server fetches its newest version's files from the
 * plane into the workspace as the message goes: a pod over its control link, a daemon with
 * its sign-in, so the files never pass through this app. Before that, on this computer,
 * each file is read with `artifact.read` through the daemon and uploaded as a picked file is.
 */
function ArtifactPicker({
  source,
  read,
  onPick,
  onClose,
}: {
  /** Where the artifacts are listed from: the plane, or this computer's daemon. */
  source: OwnPlane;
  /** The daemon to read each file through, where the server does not fetch them itself. */
  read: DaemonClient | null;
  onPick: (files: Attachment[]) => void;
  onClose: () => void;
}): JSX.Element {
  const [list, setList] = useState<Artifact[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    source.artifacts({}).then(
      (l) => live && setList(l.artifacts),
      (e: unknown) => live && setError(errorText(e)),
    );
    return () => {
      live = false;
    };
  }, [source]);

  const pick = async (a: Artifact): Promise<void> => {
    if (!read) {
      onPick([{ id: `a${++attached}`, kind: "artifact", name: a.title, artifact: { id: a.id, version: a.current ?? a.version }, about: `version ${a.current ?? a.version}` }]);
      return;
    }
    const daemon = read;
    setBusy(a.id);
    setError(null);
    try {
      const detail = await daemon.artifact(a.id);
      const n = detail.current ?? detail.version;
      const version = detail.versions.find((v) => v.n === n) ?? detail.versions[0];
      if (!version || version.files.length === 0) throw new Error(`${a.title} has no files to attach`);
      const files = await Promise.all(
        version.files.map(async (f) => {
          const read = await daemon.readArtifact(a.id, f.path, version.n);
          return { id: `a${++attached}`, kind: "file" as const, name: baseName(f.path), content: read.text, about: `from ${a.title}` };
        }),
      );
      onPick(files);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(null);
    }
  };

  return (
    <Dialog label="Add from artifacts" onClose={onClose} className="artifact-picker">
      <h1>Add from artifacts</h1>
      <p className="note">Each file of its newest version goes into the session's workspace with your message.</p>
      {error && (
        <p className="note error" role="alert">
          {error}
        </p>
      )}
      {list === null && !error && <Loading what="Reading your artifacts…" />}
      {list && list.length === 0 && <p className="note">No artifacts yet.</p>}
      {list && list.length > 0 && (
        <ul className="picker-list">
          {list.map((a) => (
            <li key={a.id}>
              <button type="button" className="item" disabled={busy !== null} onClick={() => void pick(a)}>
                <span className="t">{a.title}</span>
                <span className="d">{busy === a.id ? "Reading its files…" : `${a.kind}, version ${a.current ?? a.version}`}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
      <div className="actions">
        <button type="button" onClick={onClose}>
          Close
        </button>
      </div>
    </Dialog>
  );
}

/**
 * The composer, one box: what is attached as tags, the message, and a bar — `+` (upload
 * files, add from artifacts, add a folder), `/` (the commands), the profile the session
 * keeps, the agent chip, the context ring, and Send, which is Stop while the troupe works.
 * Enter sends, Shift+Enter starts a line; it grows with the text to 40% of the window.
 * Files dropped anywhere on the window attach. A file goes into the workspace at
 * `session:/<name>` before the message, as `/upload` puts it, and the message names it.
 */
function Composer({
  view,
  daemon,
  own,
  here,
  dormant,
  busy,
  waiting,
  looping,
  live,
  others,
  profile,
  context,
  agent,
  commands,
  onCommands,
  onSent,
}: {
  view: SessionHandle;
  daemon: DaemonClient | null;
  /** Where the person's artifacts are listed from: the plane for a session there, else the daemon. */
  own: OwnPlane | null;
  /** A session on this computer: a folder can be named, and artifacts read through its daemon. */
  here: boolean;
  dormant: boolean;
  busy: boolean;
  /** A prompt or a request that has drawn nothing for a while, in words; null otherwise. */
  waiting: string | null;
  /** A loop towards the goal is running: what is sent goes between two iterations. */
  looping: boolean;
  live: boolean;
  /** Everyone else here, who reads what is sent. */
  others: string[];
  /** The plane profile a team session keeps; null for one on this computer. */
  profile: string | null;
  context: ContextFill | undefined;
  /** The agent chip (`AgentSwitch`). */
  agent: JSX.Element;
  /** The commands, while they are open over the composer. */
  commands: JSX.Element | null;
  /** Open or shut the commands over the composer: `/` on an empty message, or the button. */
  onCommands: () => void;
  onSent: () => void;
}): JSX.Element {
  const [draft, setDraft] = useState("");
  const [files, setFiles] = useState<Attachment[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [menu, setMenu] = useState(false);
  const [artifacts, setArtifacts] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [sending, setSending] = useState(false);
  // What the agent raised when a message could not wake the session, its log unreadable to
  // it: the composer gives way to the offer to wake it past that, until it is taken.
  const [unreadable, setUnreadable] = useState<string | null>(null);
  const [waking, setWaking] = useState(false);
  const text = useRef<HTMLTextAreaElement>(null);
  const picker = useRef<HTMLInputElement>(null);
  const plus = useRef<HTMLDivElement>(null);
  const pickDirectory = shell()?.pickDirectory;

  // The box grows with what is written, to 40% of the window, then scrolls.
  useLayoutEffect(() => {
    const t = text.current;
    if (!t) return;
    t.style.height = "auto";
    t.style.height = `${Math.min(t.scrollHeight, Math.round(globalThis.innerHeight * 0.4))}px`;
  }, [draft]);

  const attach = useCallback(
    async (list: FileList | File[]): Promise<void> => {
      setError(null);
      const read = await Promise.allSettled([...list].map((f) => readAttachment(f, view.view?.maxMessageBytes)));
      const ok = read.flatMap((r) => (r.status === "fulfilled" ? [r.value] : []));
      const refused = read.flatMap((r) => (r.status === "rejected" ? [errorText(r.reason)] : []));
      if (ok.length > 0) setFiles((had) => [...had, ...ok]);
      if (refused.length > 0) setError(refused.join("; "));
    },
    [view.view],
  );

  // Files dragged anywhere onto the window attach to the message.
  useEffect(() => {
    let depth = 0;
    const carriesFiles = (e: DragEvent): boolean => Boolean(e.dataTransfer && [...e.dataTransfer.types].includes("Files"));
    const enter = (e: DragEvent): void => {
      if (!carriesFiles(e)) return;
      depth += 1;
      setDragging(true);
    };
    const leave = (): void => {
      depth = Math.max(0, depth - 1);
      if (depth === 0) setDragging(false);
    };
    const over = (e: DragEvent): void => {
      if (carriesFiles(e)) e.preventDefault();
    };
    const drop = (e: DragEvent): void => {
      if (!carriesFiles(e)) return;
      e.preventDefault();
      depth = 0;
      setDragging(false);
      if (e.dataTransfer?.files.length) void attach(e.dataTransfer.files);
    };
    globalThis.addEventListener("dragenter", enter);
    globalThis.addEventListener("dragleave", leave);
    globalThis.addEventListener("dragover", over);
    globalThis.addEventListener("drop", drop);
    return () => {
      globalThis.removeEventListener("dragenter", enter);
      globalThis.removeEventListener("dragleave", leave);
      globalThis.removeEventListener("dragover", over);
      globalThis.removeEventListener("drop", drop);
    };
  }, [attach]);

  // The + menu shuts on a press outside it.
  useEffect(() => {
    if (!menu) return;
    const outside = (e: MouseEvent): void => {
      if (!plus.current?.contains(e.target as Node)) setMenu(false);
    };
    document.addEventListener("mousedown", outside);
    return () => document.removeEventListener("mousedown", outside);
  }, [menu]);

  const submit = async (): Promise<void> => {
    const words = draft.trim();
    if ((!words && files.length === 0) || sending) return;
    const v = view.view;
    setError(null);
    setSending(true);
    try {
      // Each file into the workspace first, where `/upload` puts it; the message then says
      // where, in `/upload`'s words, and names a folder by its path.
      const lines: string[] = [];
      for (const f of files) {
        if (f.kind === "folder") {
          lines.push(`the folder ${f.name} on this computer`);
          continue;
        }
        if (!v) throw new Error("not attached: the session is not open yet");
        // The server fetches an artifact's files from the plane itself, and says where each landed.
        if (f.kind === "artifact" && f.artifact) {
          const put = await v.fsUploadArtifact(f.artifact.id, f.artifact.version === undefined ? {} : { version: f.artifact.version });
          for (const p of put.files) lines.push(`uploaded ${p.path} to session:/${p.path}`);
          continue;
        }
        const target = `session:/${f.name}`;
        await v.fsUpload(target, f.content ?? "");
        lines.push(`uploaded ${f.name} to ${target}`);
      }
      const message = [words, lines.join("\n")].filter(Boolean).join("\n\n");
      setDraft("");
      setFiles([]);
      await view.send(message);
      onSent();
    } catch (e) {
      if (repairable(e)) setUnreadable(reasonOf(e));
      else setError(errorText(e));
      setDraft((d) => d || words);
    } finally {
      setSending(false);
    }
  };

  // Woken past each event its agent cannot read, the message that could not wake it goes.
  const wake = async (): Promise<void> => {
    const v = view.view;
    if (!v) return;
    setWaking(true);
    try {
      await v.repair();
      setUnreadable(null);
      await submit();
    } catch (e) {
      setUnreadable(null);
      setError(errorText(e));
    } finally {
      setWaking(false);
    }
  };

  const addFolder = async (): Promise<void> => {
    setMenu(false);
    const path = await pickDirectory?.();
    if (path) setFiles((had) => [...had, { id: `a${++attached}`, kind: "folder", name: path, about: "folder" }]);
  };

  // What sending does right now, where it is more than Enter: said over the box.
  const state = dormant
    ? "This session is asleep. Sending wakes it, which takes about twenty seconds."
    : looping
      ? "A loop is working towards the goal. What you send goes between two of its iterations."
      : waiting
        ? waiting
        : busy
          ? "The session is working. What you send is queued and goes next."
          : !live
            ? "Not connected. What you send is held and goes when the connection comes back."
            : null;
  const canSend = (draft.trim() !== "" || files.length > 0) && !sending;
  // Attached as the artifact where the session's server fetches it from the plane itself
  // (troupe #920); else, on this computer, read through the daemon file by file.
  const fetchesArtifacts = Boolean(view.view?.capabilities[UPLOAD_ARTIFACT]);
  const artifactsWhy = !own
    ? here
      ? "Needs this computer's daemon"
      : "Sign in to the plane to list your artifacts"
    : fetchesArtifacts
      ? null
      : !here
        ? "Not yet on the platform"
        : !daemon
          ? "Needs this computer's daemon"
          : null;
  const folderWhy = !here ? "Only for sessions on this computer" : !pickDirectory ? "Needs the desktop app's folder chooser" : null;

  if (unreadable !== null) return <Unreadable sentence={unreadable} waking={waking} onWake={() => void wake()} />;

  return (
    <div className="dock">
      {(state || others.length > 0) && (
        <p className="hint">
          {state}
          {state && others.length > 0 ? " " : ""}
          {others.length > 0 &&
            (others.length === 1 ? `${others[0]} sees what you send.` : `${others.slice(0, -1).join(", ")} and ${others.at(-1)} see what you send.`)}
        </p>
      )}
      <form
        className="composer"
        onSubmit={(e) => {
          e.preventDefault();
          void submit();
        }}
      >
        {commands}
        {files.length > 0 && (
          <div className="att" aria-label="Attached">
            {files.map((f) => (
              <span key={f.id} className="file">
                <span className="glyph" aria-hidden="true">
                  {f.kind === "folder" ? "▣" : "▤"}
                </span>
                <span className="n" title={f.name}>
                  {f.name}
                </span>
                <span className="s">{f.about}</span>
                <button type="button" aria-label={`Remove ${f.name}`} onClick={() => setFiles((had) => had.filter((x) => x.id !== f.id))}>
                  ✕
                </button>
              </span>
            ))}
          </div>
        )}
        <textarea
          ref={text}
          rows={1}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          aria-label="Message"
          placeholder="Write to the troupe. Enter sends, Shift+Enter for a new line."
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault();
              void submit();
            }
            // A slash on an empty message is a command, not a message: the commands say which.
            if (e.key === "/" && draft === "") {
              e.preventDefault();
              onCommands();
            }
          }}
        />
        <div className="bar">
          <div className="plus" ref={plus}>
            <button type="button" className="ib" aria-label="Add files" aria-haspopup="true" aria-expanded={menu} onClick={() => setMenu((m) => !m)}>
              +
            </button>
            {menu && (
              <div className="pop" aria-label="Add to message">
                <button
                  type="button"
                  className="item"
                  onClick={() => {
                    setMenu(false);
                    picker.current?.click();
                  }}
                >
                  <span className="ico">↑</span>
                  <span>
                    <span className="t">Upload files</span>
                    <span className="d">Text files, into the workspace with your message. Or drop them anywhere on the window</span>
                  </span>
                </button>
                {/* Where the session's server fetches an artifact from the plane itself, a
                    pod's or a daemon's, the artifact is attached as it is (troupe #920). */}
                <button
                  type="button"
                  className="item"
                  disabled={artifactsWhy !== null}
                  onClick={() => {
                    setMenu(false);
                    setArtifacts(true);
                  }}
                >
                  <span className="ico">◇</span>
                  <span>
                    <span className="t">Add from artifacts</span>
                    <span className="d">{artifactsWhy ?? "Something you or your troupe has published"}</span>
                  </span>
                </button>
                <button type="button" className="item" disabled={folderWhy !== null} onClick={() => void addFolder()}>
                  <span className="ico">▣</span>
                  <span>
                    <span className="t">Add a folder</span>
                    <span className="d">{folderWhy ?? "Named in your message, by its path on this computer"}</span>
                  </span>
                </button>
              </div>
            )}
          </div>
          <button type="button" className="ib slash" aria-label="Commands" title="Every command, filtered as you type (/ on an empty message, or Ctrl-K)" data-palette-toggle onClick={onCommands}>
            /
          </button>
          <span className="spacer" />
          {profile && (
            <span className="chip wide" title="A session keeps the profile it started with">
              <span className="dot profile-dot" aria-hidden="true" />
              {profile}
            </span>
          )}
          {agent}
          <ContextRing fill={context} />
          {busy && (
            <button type="button" className="send stop" onClick={() => void view.cancel().catch((e: unknown) => setError(errorText(e)))} title="Stop what the troupe is doing">
              <span className="visually-hidden">Stop</span>
              <span aria-hidden="true">■</span>
            </button>
          )}
          {(!busy || canSend) && (
            <button type="submit" className="send" disabled={!canSend} title={dormant ? "Wake the session and send" : busy ? "Queued: it goes next" : "Send"}>
              <span className="visually-hidden">{dormant ? "Wake and send" : busy ? "Queue" : "Send"}</span>
              <span aria-hidden="true">↑</span>
            </button>
          )}
        </div>
        <input
          ref={picker}
          type="file"
          multiple
          hidden
          onChange={(e) => {
            if (e.target.files?.length) void attach(e.target.files);
            e.target.value = "";
          }}
        />
      </form>
      {error && (
        <p className="hint error" role="alert">
          {error}
        </p>
      )}
      {artifacts && own && (
        <ArtifactPicker
          source={own}
          read={fetchesArtifacts ? null : daemon}
          onPick={(picked) => (setFiles((had) => [...had, ...picked]), setArtifacts(false))}
          onClose={() => setArtifacts(false)}
        />
      )}
      {dragging && (
        <div className="drop" aria-hidden="true">
          <div>Drop files to hand them to the troupe</div>
        </div>
      )}
    </div>
  );
}

/** No disabled composer: a greyed-out box invites clicking at it. */
function ReadOnly(): JSX.Element {
  return (
    <div className="instead">
      <p>You can read this session but not add to it.</p>
      <p className="muted">Ask its owner to give you access if you need to take part.</p>
    </div>
  );
}

/**
 * A session whose agent cannot start from its log, in the composer's place: what it
 * raised, and the wake past what it cannot read, which the log keeps.
 */
function Unreadable({ sentence, waking, onWake }: { sentence: string; waking: boolean; onWake: () => void }): JSX.Element {
  return (
    <div className="instead stopped" role="status">
      <p>The agent could not start from this session's log: {sentence}</p>
      <p className="muted">Waking it anyway skips each event it cannot read. The log keeps them, and the transcript says where.</p>
      <button type="button" disabled={waking} onClick={onWake}>
        {waking ? "Waking" : "Wake it anyway"}
      </button>
    </div>
  );
}

/** What the server said was raised: its `data.reason`, else the whole error in words. */
function reasonOf(e: unknown): string {
  const data = (e as { data?: Record<string, unknown> }).data;
  return typeof data?.["reason"] === "string" ? data["reason"] : errorText(e);
}

/** The notes that say something went wrong: a failed model call, a stop, a message dropped. */
const ERROR_NOTES = new Set(["llm_error", "budget_exhausted", "agent_failed", "input_after_done"]);

/**
 * A session whose agent takes no more input, in the composer's place: why, and what to do.
 * No disabled box, which would invite typing a message that is dropped.
 */
function Stopped({ sentence }: { sentence: string }): JSX.Element {
  return (
    <div className="instead stopped" role="status">
      <p>{sentence}</p>
    </div>
  );
}

/**
 * The person's teams and profiles, for a publication's gate: the daemon's `artifact.list`
 * names them as the plane does for its sign-in, and failing that the plane's own `me`.
 * Asked once, when the first publication asks, and null until an answer comes.
 */
function useAudiences(daemon: DaemonClient | null, auth: AuthSession | null, wanted: boolean): Audiences | null {
  const [audiences, setAudiences] = useState<Audiences | null>(null);
  useEffect(() => {
    if (!wanted || audiences) return;
    let live = true;
    const fromMe = (): Audiences | null => (auth?.me ? { teams: auth.me.teams, profiles: auth.me.profiles } : null);
    if (daemon) {
      daemon.artifacts({ mine: true }).then(
        (l) => live && setAudiences({ teams: l.teams ?? [], profiles: l.profiles ?? [] }),
        () => live && setAudiences(fromMe()),
      );
    } else setAudiences(fromMe());
    return () => {
      live = false;
    };
  }, [daemon, auth, wanted, audiences]);
  return audiences;
}
