import { useParams } from 'react-router-dom'
import { PatientShell } from '../../components/PatientShell'
import { VisitGate } from '../../components/VisitGate'
import { ChatScreen } from '../../features/chat/ChatScreen'
import { useI18n } from '../../i18n'

export default function Chat() {
  const { id = '' } = useParams()
  const { t } = useI18n()
  return (
    <VisitGate id={id} screen="chat">
      {(visit, refetch) => (
        <PatientShell title={t('screen.chat')} back="/home" fill>
          <ChatScreen visit={visit} refetch={refetch} />
        </PatientShell>
      )}
    </VisitGate>
  )
}
