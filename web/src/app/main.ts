import '../lib/ui/tokens.css'
import './app.css'
import { mount } from 'svelte'
import App from './App.svelte'
import { applyTheme, editor } from './store.svelte'

applyTheme(editor.theme)
mount(App, { target: document.getElementById('root')! })
