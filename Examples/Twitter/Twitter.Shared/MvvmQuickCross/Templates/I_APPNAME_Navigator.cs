﻿#if TEMPLATE // To add a navigator interface class: in the Visual Studio Package Manager Console (menu View | Other Windows), enter "Install-Mvvm". Alternatively: copy this file, then in the copy remove the enclosing #if TEMPLATE ... #endif lines and replace Twitter with the application name.
namespace Twitter.Shared
{
    public interface ITwitterNavigator
    {

        /* TODO: For each view, add a method to navigate to that view with a signature like this:
        void NavigateTo_VIEWNAME_View(object navigationContext);
         * Note that the New-View command adds the above code automatically (see http://github.com/MacawNL/MvvmQuickCross#new-view). */
    }
}
#endif // TEMPLATE