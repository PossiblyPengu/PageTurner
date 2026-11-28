import { onRequest as __api_bookmaster__path__js_onRequest } from "/home/user/BookForge/functions/api/bookmaster/[path].js"

export const routes = [
    {
      routePath: "/api/bookmaster/:path",
      mountPath: "/api/bookmaster",
      method: "",
      middlewares: [],
      modules: [__api_bookmaster__path__js_onRequest],
    },
  ]