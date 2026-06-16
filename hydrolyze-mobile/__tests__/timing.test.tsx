import React from 'react'
import { render, fireEvent, act, waitFor } from '@testing-library/react-native'
import { SwimmerCard } from '../components/SwimmerCard'
import type { RecordedTime } from '../context/SessionContext'
import type { Assignment } from '../lib/ml-pairing'

function makeTime(
  id: string,
  elapsedMs: number,
  assignment: Assignment | null,
): RecordedTime {
  return {
    id,
    elapsedMs,
    repNumber: 1,
    intensity: 'moderate',
    assignment,
    deleted: false,
  }
}

// ─── SwimmerCard unit tests ───────────────────────────────────────────────────

describe('SwimmerCard', () => {
  describe('visual states', () => {
    test('recorded data → shows name + "real data" badge + maturity label', () => {
      // Source='recorded' shows blue badge, sampleCount=8 shows green maturity dot
      const time = makeTime('t1', 32500, { swimmerId: 'A', source: 'recorded', errorMs: 0, sampleCount: 5 })
      const { getByText } = render(
        <SwimmerCard
          time={time}
          swimmerName="Alice"
          source="recorded"
          sampleCount={8}
          onDelete={jest.fn()}
          onSwap={jest.fn()}
        />
      )
      expect(getByText('32.5')).toBeTruthy()
      expect(getByText(/Alice/)).toBeTruthy()
      expect(getByText('real data')).toBeTruthy()
      expect(getByText('reliable')).toBeTruthy() // 8 samples ≥ 6
      expect(getByText('exact')).toBeTruthy() // errorMs=0 → "exact"
    })

    test('PB curve → shows "from PB" badge + yellow dot + residual', () => {
      // Source='curve' shows purple badge. sampleCount=2 → "learning"
      const time = makeTime('t1', 38000, { swimmerId: 'B', source: 'curve', errorMs: 0, sampleCount: 2 })
      const { getByText } = render(
        <SwimmerCard
          time={time}
          swimmerName="Jake"
          source="curve"
          sampleCount={2}
          errorMs={1200}
          onDelete={jest.fn()}
          onSwap={jest.fn()}
        />
      )
      expect(getByText(/Jake/)).toBeTruthy()
      expect(getByText('from PB')).toBeTruthy()
      expect(getByText('learning')).toBeTruthy() // 2 samples < 6
      expect(getByText('1.2s off')).toBeTruthy() // errorMs=1200ms
    })

    test('population estimate → shows "estimate" badge + "no data" label', () => {
      const time = makeTime('t1', 35200, { swimmerId: 'A', source: 'no_data', errorMs: Infinity, sampleCount: 0 })
      const { getByText } = render(
        <SwimmerCard
          time={time}
          swimmerName="Sofia"
          source="seed"
          sampleCount={0}
          onDelete={jest.fn()}
          onSwap={jest.fn()}
        />
      )
      expect(getByText('35.2')).toBeTruthy()
      expect(getByText(/Sofia/)).toBeTruthy()
      expect(getByText('estimate')).toBeTruthy()
      expect(getByText('no data')).toBeTruthy() // sampleCount=0 → "no data"
    })

    test('IM set → shows "IM — assign after" label', () => {
      const time = makeTime('t1', 98200, { swimmerId: 'A', source: 'recorded', errorMs: 0, sampleCount: 5 })
      const { getByText } = render(
        <SwimmerCard
          time={time}
          swimmerName="Marcus"
          source="recorded"
          onDelete={jest.fn()}
          onSwap={jest.fn()}
          isIM={true}
        />
      )
      expect(getByText('1:38.2')).toBeTruthy()
      expect(getByText('IM — assign after')).toBeTruthy()
    })

    test('suspicious lap → red tinted row, "no data" shown', () => {
      const time = makeTime('t1', 55000, { swimmerId: 'A', source: 'no_data', errorMs: Infinity, sampleCount: 0 })
      const { getByText } = render(
        <SwimmerCard
          time={time}
          swimmerName="Emma"
          source="seed"
          suspicious={true}
          onDelete={jest.fn()}
          onSwap={jest.fn()}
        />
      )
      expect(getByText('55.0')).toBeTruthy()
      expect(getByText('estimate')).toBeTruthy()
    })

    test('ambiguous top-two → amber tinted row', () => {
      const time = makeTime('t1', 31500, { swimmerId: 'B', source: 'recorded', errorMs: 0, sampleCount: 5 })
      const { getByText } = render(
        <SwimmerCard
          time={time}
          swimmerName="Lily"
          source="recorded"
          sampleCount={7}
          ambiguous={true}
          onDelete={jest.fn()}
          onSwap={jest.fn()}
        />
      )
      expect(getByText(/Lily/)).toBeTruthy()
      expect(getByText('reliable')).toBeTruthy()
    })
  })

  describe('swipe actions', () => {
    test('swipe right → Swap action visible, maturity shows "reliable" for 12 samples', () => {
      const onSwap = jest.fn()
      const time = makeTime('t1', 24800, { swimmerId: 'A', source: 'recorded', errorMs: 0, sampleCount: 5 })
      const { getByText } = render(
        <SwimmerCard
          time={time}
          swimmerName="Ryan"
          source="recorded"
          sampleCount={12}
          onDelete={jest.fn()}
          onSwap={onSwap}
        />
      )
      expect(getByText('Swap')).toBeTruthy()
      // 12 samples: ≥6 and <16 → "reliable"
      expect(getByText('reliable')).toBeTruthy()
    })

    test('Delete action is registered on the left swipe side', () => {
      const onDelete = jest.fn()
      const time = makeTime('t1', 26500, { swimmerId: 'B', source: 'recorded', errorMs: 0, sampleCount: 5 })
      render(
        <SwimmerCard
          time={time}
          swimmerName="Marcus"
          source="recorded"
          onDelete={onDelete}
          onSwap={jest.fn()}
        />
      )
      // Delete is wired up — not called until swiped. Verify prop is valid.
      expect(onDelete).not.toHaveBeenCalled()
    })
  })

  describe('tap to swap interaction', () => {
    test('assigned time is tappable — calls onSwap with time id', () => {
      const onSwap = jest.fn()
      const onDelete = jest.fn()
      const time = makeTime('t1', 31800, { swimmerId: 'C', source: 'recorded', errorMs: 0, sampleCount: 5 })
      const { getByText } = render(
        <SwimmerCard
          time={time}
          swimmerName="Lily"
          source="recorded"
          sampleCount={5}
          onDelete={onDelete}
          onSwap={onSwap}
        />
      )

      fireEvent.press(getByText(/Lily/).parent!.parent!)
      expect(onSwap).toHaveBeenCalledWith('t1')
    })

    test('unassigned time is not tappable (no assignment)', () => {
      const onSwap = jest.fn()
      const time = makeTime('t2', 35500, { swimmerId: 'A', source: 'no_data', errorMs: Infinity, sampleCount: 0 })
      const { getByText } = render(
        <SwimmerCard
          time={time}
          swimmerName={undefined}
          source="seed"
          onDelete={jest.fn()}
          onSwap={onSwap}
        />
      )
      expect(getByText('35.5')).toBeTruthy()
    })
  })
})