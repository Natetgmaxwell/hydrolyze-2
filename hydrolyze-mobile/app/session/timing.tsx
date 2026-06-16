import { useState, useRef, useCallback, useEffect } from "react";
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Platform,
  Alert,
  useWindowDimensions,
} from "react-native";
import { useRouter } from "expo-router";
import { useSession } from "../../context/SessionContext";
import { pairTime } from "../../lib/ml-pairing";
import { LapButton } from "../../components/LapButton";
import { SwimmerCard } from "../../components/SwimmerCard";
import { SwapModal } from "../../components/SwapSwimmerModal";
import { ProgressionChart } from "../../components/ProgressionChart";
import { getSwimmerProgression } from "../../lib/swimmer-stats";
import {
  Colors,
  FontFamily,
  FontSize,
  Space,
  Radius,
  TouchTarget,
} from "../../lib/theme";
import type { Swimmer } from "../../lib/ml-pairing";
import type { RecordedTime } from "../../context/SessionContext";
import type { IntensityLevel } from "../../lib/set-parser";

// Volume manager — only available in dev builds (native module)
let VolumeManager:
  | typeof import("react-native-volume-manager").VolumeManager
  | null = null;
try {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  VolumeManager = require("react-native-volume-manager").VolumeManager;
} catch {
  // Expo Go / no native module — screen buttons work fine
}

const PARKED_VOLUME = 0.5;

type TimingState = "ready" | "running" | "rep_done";

export default function TimingScreen() {
  const router = useRouter();
  const { state, dispatch, activeRepTimes } = useSession();
  const { currentSet, attendanceList, statsCache, currentRepNum } = state;

  const [timingState, setTimingState] = useState<TimingState>("ready");
  const [elapsed, setElapsed] = useState(0);
  const [volumeActive, setVolumeActive] = useState(false);

  // Swap modal state
  const [swapModalVisible, setSwapModalVisible] = useState(false);
  const [swapTargetTime, setSwapTargetTime] = useState<RecordedTime | null>(
    null,
  );

  // Progression chart state
  const [selectedSwimmerId, setSelectedSwimmerId] = useState<string | null>(
    null,
  );
  const [progressionData, setProgressionData] = useState<{
    points: {
      date: string;
      timeMs: number;
      repPosition: number;
      isPB: boolean;
    }[];
    pb: { timeMs: number; date: string } | null;
  } | null>(null);
  const [loadingProgression, setLoadingProgression] = useState(false);

  // Refs — synchronous access in callbacks, no React batching
  const candidatePoolRef = useRef<Swimmer[]>([...attendanceList]);
  const repStartTime = useRef<number>(0);
  const clockInterval = useRef<ReturnType<typeof setInterval> | null>(null);
  const timingStateRef = useRef<TimingState>("ready");

  timingStateRef.current = timingState;

  const swimmerMap = Object.fromEntries(
    attendanceList.map((s) => [s.id, s.name]),
  );

  const { width: screenWidth } = useWindowDimensions();

  // ─── Progression chart fetch ────────────────────────────────────────────────

  async function loadProgression(swimmerId: string) {
    if (!currentSet) return;
    const intensity =
      currentSet.intensityPattern[currentRepNum - 1] ?? "moderate";
    setLoadingProgression(true);
    try {
      const result = await getSwimmerProgression(
        swimmerId,
        currentSet.distance,
        currentSet.stroke,
        intensity,
        currentSet.gear?.[0] ?? null,
        28,
      );
      setProgressionData(result);
    } catch (e) {
      console.error("[Timing] progression load error:", e);
      setProgressionData(null);
    } finally {
      setLoadingProgression(false);
    }
  }

  function handleSelectSwimmer(swimmerId: string) {
    setSelectedSwimmerId(swimmerId);
    loadProgression(swimmerId);
  }

  function buildSetLabel(): string {
    if (!currentSet) return "";
    const intensity =
      currentSet.intensityPattern[currentRepNum - 1] ?? "moderate";
    return `${currentSet.distance}m ${currentSet.stroke} @ ${intensity}`;
  }

  // ─── Volume button setup ─────────────────────────────────────────────────
  useEffect(() => {
    if (!VolumeManager || Platform.OS !== "ios") return;

    let active = true;

    async function setup() {
      try {
        await VolumeManager!.showNativeVolumeUI({ enabled: false });
        await VolumeManager!.setVolume(PARKED_VOLUME, { showUI: false });
        setVolumeActive(true);
      } catch {
        // fall back to screen buttons
      }
    }

    setup();

    const subscription = VolumeManager!.addVolumeListener((result) => {
      if (!active) return;
      const v = result.volume;

      if (v > PARKED_VOLUME + 0.05) {
        handleVolumeUp();
        VolumeManager!.setVolume(PARKED_VOLUME, { showUI: false });
      } else if (v < PARKED_VOLUME - 0.05) {
        VolumeManager!.setVolume(PARKED_VOLUME, { showUI: false });
      }
    });

    return () => {
      active = false;
      subscription.remove();
      VolumeManager!.showNativeVolumeUI({ enabled: true }).catch(() => {});
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  function handleVolumeUp() {
    if (timingStateRef.current === "ready") {
      startRep();
    } else if (timingStateRef.current === "running") {
      handleLap();
    }
  }

  // ─── Clock ───────────────────────────────────────────────────────────────

  function startRep() {
    if (timingStateRef.current !== "ready") return;
    candidatePoolRef.current = [...attendanceList];
    repStartTime.current = Date.now();
    setElapsed(0);
    setTimingState("running");
    timingStateRef.current = "running";
    clockInterval.current = setInterval(() => {
      setElapsed(Date.now() - repStartTime.current);
    }, 100);
  }

  function stopClock() {
    if (clockInterval.current) {
      clearInterval(clockInterval.current);
      clockInterval.current = null;
    }
  }

  // ─── Lap ─────────────────────────────────────────────────────────────────

  const handleLap = useCallback(() => {
    if (timingStateRef.current !== "running") return;
    const pool = candidatePoolRef.current;
    if (pool.length === 0) return;

    const lapTime = Date.now() - repStartTime.current;
    const stroke = currentSet!.stroke;
    const repIntensity =
      currentSet!.intensityPattern[currentRepNum - 1] ?? undefined;
    const assignment = pairTime(
      lapTime,
      pool,
      statsCache,
      stroke,
      repIntensity,
      currentSet!.paceTargetDistance ?? currentSet!.distance,
      currentSet!.gear?.[0] ?? null,
    );

    if (assignment) {
      candidatePoolRef.current = pool.filter(
        (s) => s.id !== assignment.swimmerId,
      );
    }

    dispatch({
      type: "RECORD_TIME",
      payload: {
        elapsed: lapTime,
        assignment,
        intensity: repIntensity ?? null,
      },
    });

    if (candidatePoolRef.current.length === 0) {
      stopClock();
      setTimingState("rep_done");
      timingStateRef.current = "rep_done";
    }
  }, [statsCache, currentSet, dispatch, currentRepNum]);

  function handleStop() {
    stopClock();
    setTimingState("rep_done");
    timingStateRef.current = "rep_done";
  }

  function handleReset() {
    const confirmed =
      Platform.OS === "web"
        ? window.confirm(
            "Reset current rep? All times for this rep will be cleared.",
          )
        : true;

    if (!confirmed) return;

    stopClock();
    dispatch({ type: "RESET_REP" });
    setTimingState("ready");
    timingStateRef.current = "ready";
    setElapsed(0);
    candidatePoolRef.current = [...attendanceList];
  }

  function handleNextRep() {
    dispatch({ type: "ADVANCE_REP" });
    setTimingState("ready");
    timingStateRef.current = "ready";
    setElapsed(0);
  }

  function handleEndSet() {
    router.push("/session/results");
  }

  // ─── Delete ───────────────────────────────────────────────────────────────

  function handleDeleteTime(id: string) {
    dispatch({ type: "DELETE_TIME", payload: { id } });
  }

  // ─── Swap ────────────────────────────────────────────────────────────────

  function openSwapModal(id: string) {
    const time = activeRepTimes.find((t) => t.id === id);
    if (!time) return;
    setSwapTargetTime(time);
    setSwapModalVisible(true);
  }

  function handleSwapConfirm(newSwimmerId: string) {
    if (!swapTargetTime) return;
    dispatch({
      type: "ASSIGN_TIME",
      payload: { id: swapTargetTime.id, swimmerId: newSwimmerId },
    });
  }

  useEffect(() => () => stopClock(), []);

  const totalReps = currentSet?.reps ?? 1;
  const isLastRep = currentRepNum >= totalReps;
  const isIMSet = currentSet?.stroke === "IM";

  function formatMs(ms: number) {
    const mins = Math.floor(ms / 60000);
    const secs = ((ms % 60000) / 1000).toFixed(1).padStart(4, "0");
    return mins > 0 ? `${mins}:${secs}` : (ms / 1000).toFixed(1);
  }

  // The pool visible in the swap modal — all attendance for this set
  const swapPool: Swimmer[] = attendanceList;

  // ─── State A — Ready ─────────────────────────────────────────────────────

  if (timingState === "ready") {
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <Text style={styles.repLabel}>
            REP {currentRepNum} OF {totalReps}
          </Text>
          <Text style={styles.setLabel}>
            {currentSet?.distance}m {currentSet?.stroke}
          </Text>
          {volumeActive && (
            <Text style={styles.volumeHint}>Volume Up to start</Text>
          )}
        </View>

        {/* Swimmer picker for progression chart */}
        <View style={styles.swimmerPickerRow}>
          {selectedSwimmerId ? (
            <TouchableOpacity
              style={styles.swimmerPickerBtn}
              onPress={() =>
                Alert.alert(
                  "Select Swimmer",
                  undefined,
                  attendanceList.map((s) => ({
                    text: swimmerMap[s.id] ?? s.id,
                    onPress: () => handleSelectSwimmer(s.id),
                  })),
                )
              }
              activeOpacity={0.7}
            >
              <Text style={styles.swimmerPickerLabel}>Showing:</Text>
              <Text style={styles.swimmerPickerName}>
                {swimmerMap[selectedSwimmerId] ?? selectedSwimmerId}
              </Text>
              <Text style={styles.swimmerPickerChevron}>▾</Text>
            </TouchableOpacity>
          ) : (
            <TouchableOpacity
              style={styles.swimmerPickerBtn}
              onPress={() =>
                Alert.alert(
                  "Select Swimmer for Progression",
                  "Tap a swimmer to see their history for this set",
                  attendanceList.map((s) => ({
                    text: swimmerMap[s.id] ?? s.id,
                    onPress: () => handleSelectSwimmer(s.id),
                  })),
                )
              }
              activeOpacity={0.7}
            >
              <Text style={styles.swimmerPickerPlaceholder}>
                Tap to select a swimmer
              </Text>
            </TouchableOpacity>
          )}
        </View>

        {/* Progression chart — appears once a swimmer is selected */}
        {selectedSwimmerId && (
          <ProgressionChart
            points={progressionData?.points ?? []}
            pb={progressionData?.pb ?? null}
            setLabel={buildSetLabel()}
            width={screenWidth - Space[8]}
            loading={loadingProgression}
          />
        )}

        <TouchableOpacity
          style={styles.startButton}
          onPress={startRep}
          activeOpacity={0.85}
        >
          <Text style={styles.startText}>START</Text>
        </TouchableOpacity>

        {swapTargetTime && (
          <SwapModal
            visible={swapModalVisible}
            recordedTimeMs={swapTargetTime.elapsedMs}
            currentAssignment={swapTargetTime.assignment}
            currentSwimmerName={
              swapTargetTime.assignment
                ? swimmerMap[swapTargetTime.assignment.swimmerId]
                : undefined
            }
            pool={swapPool}
            statsCache={statsCache}
            stroke={currentSet?.stroke ?? "Free"}
            intensity={
              (currentSet?.intensityPattern[
                currentRepNum - 1
              ] as IntensityLevel) ?? undefined
            }
            distance={
              currentSet?.paceTargetDistance ?? currentSet?.distance ?? 50
            }
            gear={currentSet?.gear?.[0] ?? null}
            onSelect={handleSwapConfirm}
            onClose={() => {
              setSwapModalVisible(false);
              setSwapTargetTime(null);
            }}
          />
        )}
      </View>
    );
  }

  // ─── State B — Running ────────────────────────────────────────────────────

  if (timingState === "running") {
    const remaining = candidatePoolRef.current.length;
    return (
      <View style={styles.container}>
        {/* Progression chart — above clock during run */}
        {selectedSwimmerId && !loadingProgression && (
          <ProgressionChart
            points={progressionData?.points ?? []}
            pb={progressionData?.pb ?? null}
            setLabel={buildSetLabel()}
            width={screenWidth - Space[8]}
            loading={false}
          />
        )}

        <View style={styles.clockArea}>
          <Text style={styles.clock}>{formatMs(elapsed)}</Text>
          <Text style={styles.poolCount}>
            {remaining} {remaining === 1 ? "swimmer" : "swimmers"} remaining
            {volumeActive ? "  ·  Vol Up = LAP" : ""}
          </Text>
        </View>

        <ScrollView
          style={styles.timesList}
          contentContainerStyle={styles.timesContent}
        >
          {[...activeRepTimes].reverse().map((t) => (
            <SwimmerCard
              key={t.id}
              time={t}
              swimmerName={
                t.assignment ? swimmerMap[t.assignment.swimmerId] : undefined
              }
              onDelete={handleDeleteTime}
              onSwap={openSwapModal}
              isIM={isIMSet}
            />
          ))}
        </ScrollView>

        <View style={styles.lapArea}>
          <LapButton onPress={handleLap} style={styles.lapButton} />
          <View style={styles.actionRow}>
            <TouchableOpacity
              style={styles.actionButton}
              onPress={handleReset}
              activeOpacity={0.7}
            >
              <Text style={styles.resetText}>RESET</Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={styles.actionButton}
              onPress={handleStop}
              activeOpacity={0.7}
            >
              <Text style={styles.stopText}>STOP</Text>
            </TouchableOpacity>
          </View>
        </View>

        <SwapModal
          visible={swapModalVisible}
          recordedTimeMs={swapTargetTime?.elapsedMs ?? 0}
          currentAssignment={swapTargetTime?.assignment ?? null}
          currentSwimmerName={
            swapTargetTime?.assignment
              ? swimmerMap[swapTargetTime.assignment.swimmerId]
              : undefined
          }
          pool={swapPool}
          statsCache={statsCache}
          stroke={currentSet?.stroke ?? "Free"}
          intensity={
            (currentSet?.intensityPattern[
              currentRepNum - 1
            ] as IntensityLevel) ?? undefined
          }
          distance={
            currentSet?.paceTargetDistance ?? currentSet?.distance ?? 50
          }
          gear={currentSet?.gear?.[0] ?? null}
          onSelect={handleSwapConfirm}
          onClose={() => {
            setSwapModalVisible(false);
            setSwapTargetTime(null);
          }}
        />
      </View>
    );
  }

  // ─── State C — Rep done ───────────────────────────────────────────────────

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.repLabel}>REP {currentRepNum} DONE</Text>
      </View>

      <ScrollView
        style={styles.timesList}
        contentContainerStyle={styles.timesContent}
      >
        {activeRepTimes
          .filter((t) => !t.deleted)
          .map((t) => (
            <SwimmerCard
              key={t.id}
              time={t}
              swimmerName={
                t.assignment ? swimmerMap[t.assignment.swimmerId] : undefined
              }
              onDelete={handleDeleteTime}
              onSwap={openSwapModal}
            />
          ))}
      </ScrollView>

      <View style={styles.footer}>
        <TouchableOpacity
          style={styles.secondaryButton}
          onPress={handleReset}
          activeOpacity={0.7}
        >
          <Text style={styles.secondaryButtonText}>Reset Rep</Text>
        </TouchableOpacity>
        {isLastRep ? (
          <TouchableOpacity
            style={styles.primaryButton}
            onPress={handleEndSet}
            activeOpacity={0.85}
          >
            <Text style={styles.primaryButtonText}>End Set</Text>
          </TouchableOpacity>
        ) : (
          <TouchableOpacity
            style={styles.primaryButton}
            onPress={handleNextRep}
            activeOpacity={0.85}
          >
            <Text style={styles.primaryButtonText}>Next Rep</Text>
          </TouchableOpacity>
        )}
      </View>

      <SwapModal
        visible={swapModalVisible}
        recordedTimeMs={swapTargetTime?.elapsedMs ?? 0}
        currentAssignment={swapTargetTime?.assignment ?? null}
        currentSwimmerName={
          swapTargetTime?.assignment
            ? swimmerMap[swapTargetTime.assignment.swimmerId]
            : undefined
        }
        pool={swapPool}
        statsCache={statsCache}
        stroke={currentSet?.stroke ?? "Free"}
        intensity={
          (currentSet?.intensityPattern[currentRepNum - 1] as IntensityLevel) ??
          undefined
        }
        distance={currentSet?.paceTargetDistance ?? currentSet?.distance ?? 50}
        gear={currentSet?.gear?.[0] ?? null}
        onSelect={handleSwapConfirm}
        onClose={() => {
          setSwapModalVisible(false);
          setSwapTargetTime(null);
        }}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: Colors.base },

  header: {
    paddingHorizontal: Space[6],
    paddingTop: Space[6],
    paddingBottom: Space[4],
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  repLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 1.2,
    marginBottom: Space[1],
  },
  setLabel: {
    fontFamily: FontFamily.monoMedium,
    fontSize: FontSize.base,
    color: Colors.muted,
  },
  volumeHint: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.dim,
    marginTop: Space[2],
  },

  startButton: {
    margin: Space[6],
    marginTop: Space[8],
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.lap,
    justifyContent: "center",
    alignItems: "center",
    boxShadow: `0 0 16px ${Colors.cyanGlow}`,
    elevation: 8,
  },
  startText: {
    fontFamily: FontFamily.mono,
    fontSize: FontSize.lg,
    color: "#000",
    letterSpacing: 3,
  },

  clockArea: {
    alignItems: "center",
    paddingTop: Space[6],
    paddingBottom: Space[4],
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  clock: {
    fontFamily: FontFamily.mono,
    fontSize: FontSize.timer,
    color: Colors.text,
    textAlign: "center",
    includeFontPadding: false,
  },
  poolCount: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
    marginTop: Space[1],
  },

  timesList: { flex: 1 },
  timesContent: { paddingBottom: Space[4] },

  lapArea: {
    borderTopWidth: 1,
    borderTopColor: Colors.border,
    paddingTop: Space[4],
    paddingBottom: Space[6],
  },
  lapButton: { marginBottom: Space[3] },
  actionRow: {
    flexDirection: "row",
    justifyContent: "space-evenly",
    alignItems: "center",
    paddingHorizontal: Space[6],
  },
  actionButton: {
    height: 44,
    minWidth: 80,
    alignItems: "center",
    justifyContent: "center",
  },
  stopText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.danger,
    letterSpacing: 0.8,
  },
  resetText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.muted,
    letterSpacing: 0.8,
  },

  footer: {
    padding: Space[4],
    borderTopWidth: 1,
    borderTopColor: Colors.border,
    gap: Space[3],
  },
  primaryButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.lap,
    alignItems: "center",
    justifyContent: "center",
    boxShadow: `0 0 12px ${Colors.cyanGlow}`,
    elevation: 4,
  },
  primaryButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: "#000",
    fontWeight: "600",
  },
  secondaryButton: {
    backgroundColor: Colors.elevated,
    borderRadius: Radius.lg,
    height: 44,
    alignItems: "center",
    justifyContent: "center",
    borderWidth: 1,
    borderColor: Colors.border,
  },
  secondaryButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.muted,
  },

  swimmerPickerRow: {
    paddingHorizontal: Space[4],
    paddingTop: Space[3],
    paddingBottom: Space[2],
  },
  swimmerPickerBtn: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    borderWidth: 1,
    borderColor: Colors.border,
    paddingHorizontal: Space[3],
    paddingVertical: Space[2],
    gap: Space[2],
  },
  swimmerPickerLabel: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
  },
  swimmerPickerName: {
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.sm,
    color: Colors.text,
    flex: 1,
  },
  swimmerPickerChevron: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.muted,
  },
  swimmerPickerPlaceholder: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
    fontStyle: "italic",
  },
});
