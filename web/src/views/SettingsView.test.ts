import { describe, expect, test } from 'bun:test'
import { s3ProfileFromForm, validateS3Profile } from './SettingsView'

function formData(values: Record<string, string>): FormData {
  const data = new FormData()
  for (const [name, value] of Object.entries(values)) data.append(name, value)
  return data
}

const completeProfile = {
  name: 'default-s3',
  endpoint: 'https://s3.example.com',
  region: 'ap-northeast-1',
  bucket: 'bucket-name',
  keyPrefix: 'profiles/default',
  accessKeyIdEnv: 'AWS_ACCESS_KEY_ID',
  secretAccessKeyEnv: 'AWS_SECRET_ACCESS_KEY',
  sessionTokenEnv: 'AWS_SESSION_TOKEN',
}

describe('S3 profile form reading', () => {
  test('trims every field and keeps the session token optional', () => {
    const profile = s3ProfileFromForm(formData({
      name: '  default-s3 ',
      endpoint: ' https://s3.example.com ',
      region: ' ap-northeast-1 ',
      bucket: ' bucket-name ',
      keyPrefix: ' profiles/default ',
      accessKeyIdEnv: ' AWS_ACCESS_KEY_ID ',
      secretAccessKeyEnv: ' AWS_SECRET_ACCESS_KEY ',
      sessionTokenEnv: '   ',
    }))
    expect(profile).toEqual({ ...completeProfile, sessionTokenEnv: null })
  })

  test('reads a blank form as empty strings rather than undefined', () => {
    expect(s3ProfileFromForm(formData({}))).toEqual({
      name: '',
      endpoint: '',
      region: '',
      bucket: '',
      keyPrefix: '',
      accessKeyIdEnv: '',
      secretAccessKeyEnv: '',
      sessionTokenEnv: null,
    })
  })
})

describe('S3 profile validation parity with the native editor', () => {
  test('accepts a fully populated profile', () => {
    expect(validateS3Profile(completeProfile)).toBeUndefined()
    expect(validateS3Profile({ ...completeProfile, sessionTokenEnv: null, keyPrefix: '' })).toBeUndefined()
  })

  for (const field of ['name', 'endpoint', 'region', 'bucket'] as const) {
    test(`requires ${field}`, () => {
      expect(validateS3Profile({ ...completeProfile, [field]: '' }))
        .toBe('name, endpoint, region, and bucket are required.')
    })
  }

  test('requires the endpoint to be a URL', () => {
    expect(validateS3Profile({ ...completeProfile, endpoint: 'not a url' }))
      .toBe('endpoint must be a valid URL.')
  })

  for (const field of ['accessKeyIdEnv', 'secretAccessKeyEnv'] as const) {
    test(`requires ${field}`, () => {
      expect(validateS3Profile({ ...completeProfile, [field]: '' }))
        .toBe('access key and secret key environment variable names are required.')
    })
  }
})
