export const AgentNotifyPlugin = async () => {
  const home = process.env.HOME ?? ""
  const script = `${home}/.local/bin/agent-notify`
  const send = async (payload) => {
    try {
      await Bun.$`printf %s ${JSON.stringify(payload)} | ${script} opencode`.quiet().nothrow()
    } catch {}
  }
  const dirOf = (props) =>
    props?.info?.directory ?? props?.directory ?? ""
  return {
    event: async ({ event }) => {
      const t = event?.type
      if (
        t === "session.idle" ||
        t === "session.error" ||
        t === "permission.asked"
      ) {
        const p = event.properties ?? {}
        await send({
          event: t,
          message: p.message ?? p.error ?? "",
          type: p.type ?? "",
          pattern: p.pattern ?? "",
          directory: dirOf(p),
        })
      }
    },
  }
}
