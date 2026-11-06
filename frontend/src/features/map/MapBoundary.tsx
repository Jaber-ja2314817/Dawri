import { Component, type ReactNode } from 'react'
import type { MapFailure } from './tiles'

interface Props {
  onFail: (reason: MapFailure) => void
  children: ReactNode
}

/** The map's own code failing to load is one more way of having no map. */
export class MapBoundary extends Component<Props, { failed: boolean }> {
  state = { failed: false }

  static getDerivedStateFromError() {
    return { failed: true }
  }

  componentDidCatch() {
    this.props.onFail('code')
  }

  render() {
    return this.state.failed ? null : this.props.children
  }
}
