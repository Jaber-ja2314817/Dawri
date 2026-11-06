import { useParams } from 'react-router-dom'
import { VisitGate } from '../../components/VisitGate'

/** /visit/:id goes to wherever the visit is now. */
export default function VisitRedirect() {
  const { id = '' } = useParams()
  return <VisitGate id={id} />
}
