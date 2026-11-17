# Sync engine state machine

What `SyncEngine` and `Outbox` do today, one row per transition, each pinned by a test in
`Packages/SideAProtocol/Tests/SideARemoteKitTests`. Read it with [the protocol's client sync
section](protocol.md#client-sync-sidearemotekit). A refactor that changes a row changes a test.

Rows marked **wrong** are transitions found to be wrong while pinning; they are listed at the end with what was done.

## Where it lives

`SyncEngine` (an actor) owns the connection: the run loop, sockets, timers, the outbox drain and what is published.
`Reconciler` (a value, `Reconciler.swift`) owns merging what the Mac says: the snapshot, events in sequence and REST
lists. Its methods change the value and return what the engine must do (`Effect`, `Receipt`); it has no network or
clock, and its rules (S1 to S5, C3, C11) are tested on their own in `ReconcilerTests`.

## Connection

`Connection` is `idle`, `connecting`, `live(since)`, `offline(retryAt, reason)`, `unpaired`, `needsUpdate(mac)` and
`keyChanged`. `unpaired`, `needsUpdate` and `keyChanged` are **terminal**: no wait or retry replaces them, only the
Mac's next answer does. The run loop is `greet` (`GET /v1/hello`), then `connect` (the events socket), then a wait.

| Row | From | Event | To | Test |
| --- | --- | --- | --- | --- |
| C1 | idle | `start()` | connecting; hello answered keeps `hello` and `address`; welcome makes it `live` | `startShowsConnectingUntilHelloAnswersThenLiveOnWelcome` |
| C1 | any | no token in the credential store | unpaired, loop ends | `closeCodesSetTheConnection` |
| C2 | live | welcome with `replay` and the same epoch | events apply at once | `aSkippedEventReconnectsWithLastSeq` |
| C2 | live | welcome without `replay`, or another epoch | events held until a snapshot | `aWelcomeThatCannotReplayHoldsEventsUntilTheSnapshot`, `aNewEpochTakesTheSnapshotWholesale` |
| C2 | live | welcome with `snapshotOverREST` | `GET /v1/state` applied before live events; a failure there is a backoff | `aLargeSnapshotComesOverREST` |
| C3 | live | event with `seq <= stored`, or while a snapshot is awaited | ignored | `eventsBehindAreIgnoredAndEventsAheadReconnect` |
| C3 | live | event with `seq > stored + 1` | socket closed 1000, reconnect at once with `lastSeq` | `aSkippedEventReconnectsWithLastSeq` |
| C4 | live | close 4401 | unpaired, loop ends, state kept, nothing asked until `reconnectNow()` or a foreground | `revokedAfterGoingLiveKeepsTheStateAndStopsAsking`, `removedComesBackWithTheForeground` |
| C4 | connecting | hello says `paired: false` | unpaired, loop ends | `helloDecidesWhetherToConnect` |
| C4 | live | a queued item gets 401 that isn't a missing signature | item given back, run halted, unpaired | `aRevokedTokenGivesTheClaimedItemBack`, `unauthorizedStopsDraining` |
| C5 | connecting | hello 401 (a Mac that checks the token there) | backoff with the Mac's message; not unpaired | `aHelloRefusedWith401IsABackoffNotARevocation` |
| C5 | connecting | hello 503 | backoff | `aMacThatCantReadItsDevicesIsntARemoval` |
| C6 | connecting | hello says this phone is too old (`minClientBuild`) | needsUpdate(mac: false), loop ends, no polling | `helloDecidesWhetherToConnect`, `onlyAMacThatIsTooOldIsAskedAgainOnItsOwn` |
| C6 | connecting | hello says the Mac is too old (`maxProtocol`) or 426 `upgrade_mac` | needsUpdate(mac: true), hello again every `updateCheck` (15 s), nothing else shown in between | `aMacThatWasTooOldIsFoundAgainOnceItUpdates`, `onlyAMacThatIsTooOldIsAskedAgainOnItsOwn` |
| C6 | needsUpdate, loop ended | `reconnectNow()` or foreground | one more hello, the loop starts again | `needsUpdateComesBackWhenAskedAgain`, `needsUpdateComesBackWithTheForeground` |
| C7 | live | close 4426 (reason contains `mac`: Mac side) | as C6 | `theSocketsOwnRefusalForAnUpdateEndsOrPollsLikeHelloDoes`, `closeCodesSetTheConnection` |
| C8 | live | close 4429 | offline "Too many connections to the Mac", wait 10 s; foreground skips it | `tooManyConnectionsWaitsAndAForegroundSkipsIt` |
| C9 | live | close 1001 after `bye(reason)` | offline "Side A on the Mac closed (reason)", backoff | `closeReasonsBecomeTheOfflineReason`, `anyOtherGoodbyeIsntSleep` |
| C9 | live | any other close | offline with the Mac's reason or "Connection closed (code)", backoff | `closeReasonsBecomeTheOfflineReason` |
| C10 | live | close 4008 (also what the engine itself uses for a missed pong) | reconnect at once, up to 3 in a row; the 4th backs off "Connection kept dropping" | `aMacThatKeepsReplayingAGapIsNotCalledBackWithoutEnd`, `immediateReconnectsGiveWayToABackoffWithItsReason`, `aFailedPongClosesTheSocketAndReconnects` |
| C11 | live | frame that doesn't decode, its `seq` is the next | `seq` advances, state read again over REST | `anEventThatDoesNotDecodeStillTakesItsPlaceInTheSequence` |
| C11 | live | frame that doesn't decode, any other `seq`, or not JSON | ignored | `anUndecodableFrameOutOfSequenceIsIgnored` |
| C12 | any | `stop()` | idle, socket closed 1000, state kept; no foreground or `reconnectNow()` starts it; `start()` begins a new run from the held `seq` | `stopClosesTheSocketKeepsTheStateAndEndsThePolling`, `aStoppedEngineStaysStopped` |
| C12 | live | `stop()`, `start()`, the old socket closes late | the new socket is left alone | `aHaltedRunsLateCloseLeavesTheNewSocketAlone` |
| C13 | live | background | presence `foreground: false`; socket, pings and state untouched | `backgroundingOnlyTellsTheMac` |
| C13 | live | foreground | ping to prove the socket (a failed pong closes it 4008); presence | `theForegroundAsksALiveSocketToProveIt`, `aPongFailureFromAnEarlierSocketLeavesTheNewOneAlone` |
| C14 | offline, waiting | foreground, `reconnectNow()` | the wait ends | `aForegroundDuringABackoffSkipsIt` |
| C15 | connecting | every address answers with another TLS key | keyChanged, loop ends (one address doing so only tries the next) | `aNewKeyOnEveryAddressMeansPairAgain`, `aNewKeyOnOneAddressFallsBackToTheNext`, `aNewKeyComesBackWithTheForeground` |
| C16 | connecting | an address fails | the next address at once; the backoff only after all of them | `anUnreachableAddressFallsBackToTheNext` |

## Why the Mac can't be reached

`Connection.offline(retryAt, reason, cause)` carries what the Mac or the relay said about why: `unknown`, `macAsleep` or
`relayRefused`. It is one value, so the two can't both be true, and no other state has one. The engine keeps the last
`cause` it was told and puts it on every `offline` it publishes; while it is set, the loop leaves the `offline`
connection in place instead of publishing `connecting`, so the phone keeps saying "asleep" through the attempts.

| Row | Event | Result | Test |
| --- | --- | --- | --- |
| F1 | `bye(sleep)` | cause `macAsleep`, shown by the next `offline` (the connection stays `live` until the socket closes) | `aGoodbyeForSleepSaysSoUntilTheMacAnswers`, `theSleepGoodbyeIsNotReplacedByRelayRefusalsOrByAnAttempt` |
| F1 | `bye(other)` | nothing | `anyOtherGoodbyeIsntSleep` |
| F2 | a hello answers | cause `unknown` on the down connection at once | `aHelloThatAnswersClearsTheCauseBeforeTheWelcome` |
| F2 | a welcome comes | `live`, cause `unknown` | `aGoodbyeForSleepSaysSoUntilTheMacAnswers`, `repeatedRefusalsOfferPairAgainAndAnAnswerTakesItBack` |
| F3 | 3 rounds of all addresses in a row, each turned away by the relay | cause `relayRefused`, unless the Mac already said it is asleep | `repeatedRefusalsOfferPairAgainAndAnAnswerTakesItBack`, `theSleepGoodbyeIsNotReplacedByRelayRefusalsOrByAnAttempt` |
| F3 | rounds that fail any other way | cause stays `unknown` | `anUnreachableMacOffersNothing` |
| F4 | `stop()`, then `start()` | `idle`; the cause is forgotten, so the first failed round after the restart is not "asleep" | `aRestartAfterStopDoesNotReportAsleep` |
| F4 | a missed pong, or a normal close, after `bye(sleep)` | the `offline` connection carries `macAsleep` (the loop ends on a normal close) | `aMissedPongAfterASleepGoodbyeStillSaysAsleep`, `aNormalCloseAfterASleepGoodbyeStillSaysAsleep` |
| F5 | a terminal state | no wait replaces it | `aTerminalStateIsNotReplacedByTheWaitsThatFollow`, `aRetryThatCantReachTheMacDoesntChangeWhatsShown` |

## State from the Mac

| Row | Event | Result | Test |
| --- | --- | --- | --- |
| S1 | `snapshot` event | replaces sessions, finished, requests, hosted, accounts, mac, incidents, autopilot, dropped replies; sets `epoch` and `seq`; clears `sliceSeq` | `aSnapshotThenEventsBuildTheState`, `aNewEpochTakesTheSnapshotWholesale` |
| S1 | `refresh()`, same epoch, `seq` behind the stream | ignored | `refreshTakesAnOlderEpochsNewerStateOnlyWhenItIsAhead` |
| S1 | `refresh()`, same epoch and `seq >= stored`, or another epoch | taken wholesale | same |
| S2 | REST list with `seq` newer than `stored.seq` and that slice's `sliceSeq` | replaces that slice, records `sliceSeq`, never moves `seq` | `eachSliceTakesOnlyAListNewerThanSeqAndItsOwnLastRefresh`, `aSliceRefreshNeverMovesSeq` |
| S2 | the next events of that slice with `seq <= sliceSeq` | `seq` advances, state unchanged | same |
| S2 | events of sessions, finished and hosted | always apply: only `requests` and `accounts` are refreshed over REST, so only they have a `sliceSeq` | same |
| S3 | REST list asked under one epoch, answered after another epoch's snapshot | left out (it was **wrong**: it replaced the slice whenever its `seq` was larger than the new epoch's) | `aSliceAnsweredAfterANewEpochsSnapshotIsLeftOut`, `aSliceAnsweredInTheSameEpochStillRefreshes` |
| S4 | `request.resolve` | request moves to `resolved` (last 50); a pending answer for it that isn't from this device settles as `answeredElsewhere` | `aResolutionFromTheMacDropsAPendingAnswer` |
| S5 | `finished.resolve(queueDropped)` | `queueDrops[session] += 1` | `aQueueTheMacGaveUpOnCountsADrop` |
| S6 | `mac.update`, `incident.update` | `mac`, `incidents` replaced | `theMacsOwnStateAndIncidentsFollowEvents` |

## Outbox

Rows are `outbox(id, mac, target, created, answer, item, claimedBy, claimedAt)`. An item's id is its Idempotency-Key.
The method and path of the four mutations (answer, reply, interrupt, take back) come from `QueuedRoutes`, which the Mac registers and classifies by too. Its target is `request:<rid>` or `session:<id>` from its path; `answer` is 1 for an answer. A claim older than 30 s is free.

| Row | From | Event | To | Test |
| --- | --- | --- | --- | --- |
| O1 | none | `enqueue` (answer, reply, interrupt, take back) | queued, shown in `pending`; a drain starts if live | `anAnswerIsOptimisticAndDeliveredWithItsKey`, `theEnginesAnswerAndReplyAreTheSharedItems` |
| O1 | none | `enqueue` the database refuses | settles `notDelivered` at once ("Not sent"), Retry offered | `aReplyThatNeverReachedTheQueueSettlesAsNotSentAndRetries`, `anEnqueueTheDatabaseRefusesThrowsAndLeavesNothingQueued` |
| O2 | queued | `claim` | claimed by the owner: answers first, then oldest per target; the owner may claim its own again | `claimsFollowAnswersFirstThenTheOldestOfEachTarget`, `answersAreClaimedFirst` |
| O2 | queued | `claim` while another process holds an earlier item of the same target | nothing for that target; other targets go | same, `anItemAnotherProcessHoldsHoldsBackItsTargetOnly` |
| O2 | claimed by another | its claim ages past 30 s, or it gives the item back, or finishes it | the drain looks again every `claimRecheck` (5 s) while items stay queued: sends it, or drops it from `pending` (it was **wrong**: nothing looked again) | `anItemBehindALapsedClaimIsSentOnceItLapses`, `anItemAnotherProcessGivesBackIsSent`, `anItemAnotherProcessDeliveredLeavesPending`, `itemsBehindAHeldOneGoAfterIt` |
| O3 | claimed | 2xx or replay | removed, `delivered(body)`; the request leaves `open` | `anAnswerIsOptimisticAndDeliveredWithItsKey` |
| O3 | claimed | 409 `already_resolved` | removed, `answeredElsewhere` | `alreadyResolvedAndOtherRefusalsLeaveTheQueue` |
| O3 | claimed | 409 `outcome_unknown` | removed, `unknown`, never retried; Retry is a tap | `anUnknownOutcomeIsNeverRetried`, `aTappedRetrySendsANewKeyAndKeepsTheFirstAttempt` |
| O3 | claimed | 401 `confirm_required`/`confirm_invalid` | removed, `failed`; still paired | `aSignedAnswerCarriesItsConfirmAndARefusedSignatureFailsOnlyThatAnswer` |
| O3 | claimed | other non-retryable error | removed, `failed(error)` | `alreadyResolvedAndOtherRefusalsLeaveTheQueue`, `inProgressIsRetriedButAnUnmarkedServerErrorIsNot` |
| O4 | claimed | retryable error or network error | `attempts + 1`, `lastError`, released; its target waits, others go; retry after `Retry-After` or backoff | `aFailedAttemptIsRecordedAndTheItemGivenBack`, `aRetryingItemHoldsBackOnlyItsOwnSession`, `inProgressIsRetriedButAnUnmarkedServerErrorIsNot` |
| O5 | queued or claimed | `expiresAt` passes, connected | claimed for settling, removed, `notDelivered` | `anExpiredItemIsNotDelivered` |
| O5 | queued | `expiresAt` passes, not connected or loop ended | the same, by the engine's own timer | `anExpiredItemSettlesWhereverTheConnectionStopped`, `anItemThatNeverReachedTheMacExpiresAndRetries` |
| O5 | claimed by another | `expiresAt` passes | looked at again every `expiryRecheck`; settles when the claim lapses; leaves `pending` when the other process finishes it | `anExpiredItemAnotherProcessHeldSettlesOnceItsClaimLapses`, `anExpiredItemAnotherProcessFinishedLeavesPending`, `claimExpiredTakesOnlyWhatNobodyHolds` |
| O6 | settled `unknown` or `notDelivered` | `retry` | new key `<first>:r<n>`, same body and lifetime; `retries` links them | `aTappedRetrySendsANewKeyAndKeepsTheFirstAttempt`, `anItemThatNeverReachedTheMacExpiresAndRetries` |
| O7 | an answer's first key settled `failed`/`unknown`/`notDelivered` | the user answers again | a new key `<rid>:<kind>:a<clock>`; otherwise the same key | `aTapAfterARefusalGoesUnderItsOwnKeyAndSettlesAlone`, `aTapAfterAnUnknownOutcomeGetsItsOwnKeyAndADeliveredOneReplays` |
| O8 | queued | `takeBack` | `DELETE /v1/sessions/<id>/mail`, queued behind that session's items, key `<session>:takeback:<clock>` | `aTakeBackRightAfterANoteGoesAfterIt` |
| O9 | any | an item that no longer decodes | deleted, the next is tried | `anItemThatDoesNotDecodeDoesNotBlockTheOnesBehindIt` |
| O9 | any | two processes enqueue and claim at once | nothing lost, nothing claimed twice | `twoProcessesEnqueueingAtOnceLoseNothingAndNeverClaimTheSameItem` |
| O9 | any | rows written by older builds | read back as written; target and answer column come from the path | `aStoredRowReadsBackAsItWasWritten`, `itemsSurviveANewOutboxOnTheSameFile` |

## Wrong today

- **S3, REST slice across an epoch change.** The lists (`RequestList` and `AccountList`) carry a `seq` and no epoch. The
  engine compares the seq with the stream's. A request started under one epoch and answered after a snapshot of the
  next one (the Mac relaunched, `seq` starts again at 0) replaces the slice whenever its old `seq` is larger than the
  new one. The new state is overwritten by the old Mac's. Fixed on `fix-slice-refresh-across-epoch`: a list is applied
  only if the epoch it was asked under is still the state's.
- **O2, a claim that lapses is not noticed.** An item behind another process's claim isn't sent, and when the claim
  lapses or is released nothing asks again: the drain ended with the empty claim, and the next drain waits for a new
  item, a reconnect or the item's expiry (ten minutes for a reply). The row says Sending… until then. Fixed on
  `fix-drain-after-a-claim-lapses`: a drain that ends with items still queued looks again after `claimRecheck`, and
  reads `pending` from the queue (a failed read keeps the last good list; an older read never replaces a newer one: `aFailedReadOfTheQueueKeepsThePendingList`).
- **`macAsleep` and `relayRefused` as separate fields** could both be true (the phone showed asleep) and `macAsleep`
  outlived `stop()`. They are one `cause` on the `offline` connection now (sm-2), and `idle` has none.
