const storage: Record<string, string> = {}
export default {
  setItem: jest.fn((key: string, val: string) => { storage[key] = val; return Promise.resolve() }),
  getItem: jest.fn((key: string) => Promise.resolve(storage[key] ?? null)),
  removeItem: jest.fn((key: string) => { delete storage[key]; return Promise.resolve() }),
}
